package service

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/hostedpi"
)

type clientProcess struct {
	binding application.HostedPiRuntimeBinding
	done    chan error
	once    sync.Once
}

func (p *clientProcess) Binding() application.HostedPiRuntimeBinding { return p.binding }
func (p *clientProcess) Wait() error                                 { return <-p.done }
func (p *clientProcess) Stop(context.Context) error                  { p.once.Do(func() { p.done <- nil }); return nil }

type clientRuntime struct{ process *clientProcess }

func (r clientRuntime) Start(_ context.Context, spec application.HostedPiLaunchSpec) (application.HostedPiOwnedProcess, error) {
	binding := r.process.binding
	binding.RuntimeID = spec.RuntimeID
	binding.Incarnation = spec.Incarnation
	binding.TmuxSession = spec.TmuxSession
	binding.TmuxSessionID = "$client" + spec.AgentID
	binding.TmuxWindow = spec.TmuxWindow
	binding.TmuxWindowID = "@client"
	binding.TmuxPane = "%client"
	return &clientProcess{binding: binding, done: make(chan error, 1)}, nil
}

func TestClientBootstrapTwoActorsAndCorrelatedPromptAnswer(t *testing.T) {
	root := t.TempDir()
	_ = os.Chmod(root, 0o700)
	for _, name := range []string{"a", "b"} {
		if err := os.Mkdir(filepath.Join(root, name), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	listener, err := net.Listen("unix", filepath.Join(root, "control.sock"))
	if err != nil {
		t.Fatal(err)
	}
	baseProcess := &clientProcess{binding: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, TmuxSessionID: "$client", TmuxWindowID: "@client", TmuxPane: "%client", PanePID: 42, ProcessStartToken: "start", TTY: "/dev/pts/42"}, done: make(chan error, 1)}
	daemon, err := startWithListener(context.Background(), listener, HostedAdminConfig{Enabled: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge", StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: filepath.Join(root, "admin.json"), DefaultProjectDirectory: root, TrustProject: true, RuntimeFactory: func(hostedpi.Config) application.HostedPiRuntime { return clientRuntime{process: baseProcess} }}, listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	request := func(payload any, session application.OpenSession, handle string, fence uint64) *subagentsv1.Envelope {
		envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: time.Now().String(), DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli(), SessionId: session.SessionID, GenerationId: session.GenerationID, CallerIdentity: session.Caller, SessionCredential: session.Credential, AgentHandle: handle, AgentFence: fence}
		switch value := payload.(type) {
		case *subagentsv1.Envelope_HostedAdminRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_ClientSessionRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_ListAgentsRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_AttachRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_BridgeConnectRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_BridgeLifecycleRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_PromptTaskRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_TaskLifecycleRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_BridgePollRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_BridgeDeliveryAckRequest:
			envelope.Payload = value
		default:
			t.Fatalf("unsupported payload %T", payload)
		}
		return daemon.dispatch(envelope)
	}
	adminSession := application.OpenSession{Credential: daemon.adminCredential}
	for index, name := range []string{"alpha", "beta"} {
		response := request(&subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: name, ProjectDirectory: filepath.Join(root, string(rune('a'+index))), TrustProject: true}}, adminSession, "", 0).GetHostedAdminResponse()
		if response == nil || !response.Accepted {
			t.Fatalf("create %s failed: %#v", name, response)
		}
	}
	if daemon.persistencePID == nil {
		t.Fatal("test requires a non-agent stale PID")
	}
	daemon.hostedMu.Lock()
	daemon.hostedRuntimes["alpha"] = daemon.persistencePID
	daemon.hostedMu.Unlock()
	if binding, err := daemon.hostedStatus(context.Background(), "alpha"); err != nil || binding.RuntimeID == "" {
		t.Fatalf("status did not repair a stale cached control PID through AgentRegistry: %#v %v", binding, err)
	}
	shared := request(&subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: "gamma", ProjectDirectory: filepath.Join(root, "a"), TrustProject: true}}, adminSession, "", 0).GetHostedAdminResponse()
	if shared == nil || shared.Accepted {
		t.Fatalf("second actor acquired an already-owned writable worktree: %#v", shared)
	}
	opened := request(&subagentsv1.Envelope_ClientSessionRequest{ClientSessionRequest: &subagentsv1.ClientSessionRequest{Operation: subagentsv1.ClientSessionRequest_OPERATION_OPEN}}, adminSession, "", 0).GetClientSessionResponse()
	if opened == nil || !opened.Accepted || len(opened.SessionCredential) != 32 {
		t.Fatalf("bootstrap failed: %#v", opened)
	}
	client := application.OpenSession{SessionID: opened.SessionId, GenerationID: opened.GenerationId, Caller: opened.CallerIdentity, Credential: opened.SessionCredential}
	listed := request(&subagentsv1.Envelope_ListAgentsRequest{ListAgentsRequest: &subagentsv1.ListAgentsRequest{}}, client, "", 0).GetListAgentsResponse()
	if listed == nil || len(listed.Agents) != 2 {
		t.Fatalf("dynamic list failed: %#v", listed)
	}
	attached := request(&subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: "alpha", RequestedCapabilities: []string{"observe", "prompt"}}}, client, "", 0).GetAttachResponse()
	if attached == nil || attached.AgentHandle == "" {
		t.Fatalf("regular attach failed: %#v", attached)
	}
	records, err := daemon.durableStore.LoadAll(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var record application.DurableHostedRecord
	for _, candidate := range records {
		if candidate.AgentID == "alpha" {
			record = candidate
		}
	}
	credential, err := hostedpi.ReadCredentialFile(record.Session.CredentialFile)
	if err != nil {
		t.Fatal(err)
	}
	host := application.OpenSession{SessionID: record.Session.SessionID, GenerationID: record.Session.GenerationID, Caller: record.Session.Caller, Credential: credential}
	connected := request(&subagentsv1.Envelope_BridgeConnectRequest{BridgeConnectRequest: &subagentsv1.BridgeConnectRequest{AgentId: "alpha", RuntimeId: record.LaunchSpec.RuntimeID, Incarnation: 1, PiSessionId: "pi-alpha"}}, host, "", 0).GetBridgeConnectResponse()
	if connected == nil || !connected.Accepted {
		t.Fatalf("host connect failed: %#v", connected)
	}
	for _, event := range []subagentsv1.BridgeLifecycleRequest_Event{subagentsv1.BridgeLifecycleRequest_EVENT_SESSION_START, subagentsv1.BridgeLifecycleRequest_EVENT_READY} {
		response := request(&subagentsv1.Envelope_BridgeLifecycleRequest{BridgeLifecycleRequest: &subagentsv1.BridgeLifecycleRequest{AgentId: "alpha", RuntimeId: record.LaunchSpec.RuntimeID, Incarnation: 1, Event: event}}, host, connected.AgentHandle, connected.Fence).GetBridgeLifecycleResponse()
		if response == nil || !response.Accepted {
			t.Fatalf("lifecycle failed: %#v", response)
		}
	}
	promptEnvelope := request(&subagentsv1.Envelope_PromptTaskRequest{PromptTaskRequest: &subagentsv1.PromptTaskRequest{Target: "alpha", BoundedPrompt: []byte("Implement the next task"), DedupeId: "prompt-1", ChainId: "chain-1", HopLimit: 8, SourceMutationSequence: 1}}, client, attached.AgentHandle, attached.Fence)
	if failure := promptEnvelope.GetProtocolError(); failure == nil || failure.Message != "prompt task retired; use actor message ask" {
		t.Fatalf("legacy prompt bypass was not retired fail-closed: %#v", promptEnvelope)
	}
	lifecycleEnvelope := request(&subagentsv1.Envelope_TaskLifecycleRequest{TaskLifecycleRequest: &subagentsv1.TaskLifecycleRequest{Operation: subagentsv1.TaskLifecycleRequest_OPERATION_START, LifecycleId: "life-1", Target: "alpha", BoundedPrompt: []byte("Observe typed lifecycle"), DedupeId: "life-dedupe", ChainId: "life-chain", HopLimit: 8, SourceMutationSequence: 2}}, client, attached.AgentHandle, attached.Fence)
	if failure := lifecycleEnvelope.GetProtocolError(); failure == nil || failure.Message != "task lifecycle retired; use actor message ask" {
		t.Fatalf("legacy lifecycle bypass was not retired fail-closed: %#v", lifecycleEnvelope)
	}
	closed := request(&subagentsv1.Envelope_ClientSessionRequest{ClientSessionRequest: &subagentsv1.ClientSessionRequest{Operation: subagentsv1.ClientSessionRequest_OPERATION_CLOSE}}, client, "", 0).GetClientSessionResponse()
	if closed == nil || !closed.Accepted {
		t.Fatalf("explicit close failed: %#v", closed)
	}
	binding, statusErr := daemon.hostedStatus(context.Background(), "alpha")
	if statusErr != nil || binding.State == application.HostedPiRuntimeStopped || binding.State == application.HostedPiRuntimeDegraded {
		t.Fatalf("ephemeral requester close killed the global hosted actor: %#v %v", binding, statusErr)
	}
}

func TestClientConcurrentCloseDoesNotPoisonFutureOpen(t *testing.T) {
	root := t.TempDir()
	_ = os.Chmod(root, 0o700)
	for _, name := range []string{"a", "b"} {
		if err := os.Mkdir(filepath.Join(root, name), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	listener, err := net.Listen("unix", filepath.Join(root, "control.sock"))
	if err != nil {
		t.Fatal(err)
	}
	baseProcess := &clientProcess{binding: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, TmuxSessionID: "$client", TmuxWindowID: "@client", TmuxPane: "%client", PanePID: 42, ProcessStartToken: "start", TTY: "/dev/pts/42"}, done: make(chan error, 1)}
	daemon, err := startWithListener(context.Background(), listener, HostedAdminConfig{Enabled: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge", StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: filepath.Join(root, "admin.json"), DefaultProjectDirectory: root, TrustProject: true, RuntimeFactory: func(hostedpi.Config) application.HostedPiRuntime { return clientRuntime{process: baseProcess} }}, listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	request := func(payload any, session application.OpenSession, requestID string, handleFence ...any) *subagentsv1.Envelope {
		envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: requestID, DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli(), SessionId: session.SessionID, GenerationId: session.GenerationID, CallerIdentity: session.Caller, SessionCredential: session.Credential}
		if len(handleFence) == 2 {
			envelope.AgentHandle = handleFence[0].(string)
			envelope.AgentFence = handleFence[1].(uint64)
		}
		switch value := payload.(type) {
		case *subagentsv1.Envelope_HostedAdminRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_ClientSessionRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_AttachRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_SubscribeAgentRequest:
			envelope.Payload = value
		default:
			t.Fatalf("unsupported payload %T", payload)
		}
		return daemon.dispatch(envelope)
	}
	adminSession := application.OpenSession{Credential: daemon.adminCredential}
	for index, name := range []string{"alpha", "beta"} {
		response := request(&subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: name, ProjectDirectory: filepath.Join(root, string(rune('a'+index))), TrustProject: true}}, adminSession, "start-"+name).GetHostedAdminResponse()
		if response == nil || !response.Accepted {
			t.Fatalf("create %s failed: %#v", name, response)
		}
	}
	opened := make([]application.OpenSession, 2)
	for index := range opened {
		response := request(&subagentsv1.Envelope_ClientSessionRequest{ClientSessionRequest: &subagentsv1.ClientSessionRequest{Operation: subagentsv1.ClientSessionRequest_OPERATION_OPEN}}, adminSession, "open-client-"+string(rune('a'+index))).GetClientSessionResponse()
		if response == nil || !response.Accepted {
			t.Fatalf("open client %d failed: %#v", index, response)
		}
		opened[index] = application.OpenSession{SessionID: response.SessionId, GenerationID: response.GenerationId, Caller: response.CallerIdentity, Credential: response.SessionCredential}
		for _, agent := range []string{"alpha", "beta"} {
			envelope := request(&subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: agent, RequestedCapabilities: []string{"observe", "prompt"}}}, opened[index], "attach-client-"+string(rune('a'+index))+"-"+agent)
			attached := envelope.GetAttachResponse()
			if attached == nil || attached.AgentHandle == "" {
				t.Fatalf("attach client %d to %s failed: %#v", index, agent, envelope)
			}
			subscribed := request(&subagentsv1.Envelope_SubscribeAgentRequest{SubscribeAgentRequest: &subagentsv1.SubscribeAgentRequest{AgentId: agent}}, opened[index], "subscribe-client-"+string(rune('a'+index))+"-"+agent, attached.AgentHandle, attached.Fence).GetAgentOperationResponse()
			if subscribed == nil || !subscribed.Completed {
				t.Fatalf("subscribe client %d to %s failed: %#v", index, agent, subscribed)
			}
		}
	}
	closed := make(chan *subagentsv1.ClientSessionResponse, 2)
	for index := range opened {
		client := opened[index]
		go func(index int) {
			closed <- request(&subagentsv1.Envelope_ClientSessionRequest{ClientSessionRequest: &subagentsv1.ClientSessionRequest{Operation: subagentsv1.ClientSessionRequest_OPERATION_CLOSE}}, client, "close-client-"+string(rune('a'+index))).GetClientSessionResponse()
		}(index)
	}
	for range opened {
		select {
		case response := <-closed:
			if response == nil || !response.Accepted {
				t.Fatalf("concurrent close failed: %#v", response)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("concurrent close timed out")
		}
	}
	reopened := request(&subagentsv1.Envelope_ClientSessionRequest{ClientSessionRequest: &subagentsv1.ClientSessionRequest{Operation: subagentsv1.ClientSessionRequest_OPERATION_OPEN}}, adminSession, "open-after-close").GetClientSessionResponse()
	if reopened == nil || !reopened.Accepted {
		t.Fatalf("future client OPEN was poisoned by concurrent CLOSE: %#v", reopened)
	}
}

func TestClientBootstrapExpires(t *testing.T) {
	root := t.TempDir()
	_ = os.Chmod(root, 0o700)
	listener, err := net.Listen("unix", filepath.Join(root, "control.sock"))
	if err != nil {
		t.Fatal(err)
	}
	oldTTL := clientSessionTTL
	clientSessionTTL = 20 * time.Millisecond
	defer func() { clientSessionTTL = oldTTL }()
	daemon, err := startWithListener(context.Background(), listener, HostedAdminConfig{Enabled: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge", StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: filepath.Join(root, "admin.json"), DefaultProjectDirectory: root}, listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	}()
	envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: "open", DeadlineUnixMillis: time.Now().Add(time.Second).UnixMilli(), SessionCredential: daemon.adminCredential, Payload: &subagentsv1.Envelope_ClientSessionRequest{ClientSessionRequest: &subagentsv1.ClientSessionRequest{Operation: subagentsv1.ClientSessionRequest_OPERATION_OPEN}}}
	opened := daemon.dispatch(envelope).GetClientSessionResponse()
	if opened == nil || !opened.Accepted {
		t.Fatal("bootstrap failed")
	}
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		value, _ := daemon.system.NoSender().Ask(context.Background(), daemon.sessionRegistry, &application.SessionAuthorization{SessionID: opened.SessionId, GenerationID: opened.GenerationId, Caller: opened.CallerIdentity, Credential: opened.SessionCredential, Capability: "observe"}, requestTimeout)
		if result, ok := value.(*application.AuthorizationResult); ok && !result.Allowed {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("ephemeral client session did not expire")
}
