//go:build linux

package service_test

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/hostedpi"
	"github.com/savioserra/lazyvim/services/subagents/internal/service"
)

type capturingRuntime struct {
	delegate *hostedpi.Runtime
	started  chan application.HostedPiOwnedProcess
}

func (r capturingRuntime) Start(ctx context.Context, spec application.HostedPiLaunchSpec) (application.HostedPiOwnedProcess, error) {
	process, err := r.delegate.Start(ctx, spec)
	if err == nil {
		r.started <- process
	}
	return process, err
}

func TestRealInstalledPiHostedBridgeIsolatedTmuxSmoke(t *testing.T) {
	if os.Getenv("RUN_REAL_HOSTED_PI_SMOKE") != "1" {
		t.Skip("set RUN_REAL_HOSTED_PI_SMOKE=1 for the installed Pi/tmux smoke")
	}
	tmux, err := exec.LookPath("tmux")
	if err != nil {
		t.Fatal("RUN_REAL_HOSTED_PI_SMOKE=1 but tmux is unavailable")
	}
	pi, err := exec.LookPath("pi")
	if err != nil {
		t.Fatal("RUN_REAL_HOSTED_PI_SMOKE=1 but installed Pi is unavailable")
	}
	repository, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	bridge := filepath.Join(repository, "home", "dot_pi", "private_agent", "extensions", "hosted-pi-bridge", "index.ts")
	if _, err := os.Stat(bridge); err != nil {
		t.Fatal(err)
	}

	root := privateTempDir(t)
	socket := filepath.Join(root, "runtime", "control.sock")
	daemon, err := service.Start(context.Background(), socket)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	credential := []byte(strings.Repeat("r", 32))
	credentialPath := filepath.Join(root, "bridge-credential.json")
	if err := os.WriteFile(credentialPath, []byte(fmt.Sprintf("{\"credential_b64\":%q}\n", base64.StdEncoding.EncodeToString(credential))), 0o600); err != nil {
		t.Fatal(err)
	}
	bridgeSession := application.OpenSession{SessionID: "real-bridge-session", GenerationID: "real-bridge-generation", Caller: "hosted:real-agent", Credential: credential, Capabilities: []string{"observe", "hosted_bridge", "send", "ask", "control_abort", "control_shutdown"}, ExpiresAt: time.Now().Add(time.Hour)}
	if err := daemon.OpenSession(context.Background(), bridgeSession); err != nil {
		t.Fatal(err)
	}

	tmuxTemporary, err := os.MkdirTemp("/tmp", "ws-hp-")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(tmuxTemporary, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(tmuxTemporary) })
	t.Setenv("TMUX_TMPDIR", tmuxTemporary)
	server := fmt.Sprintf("ws-hosted-smoke-%d", os.Getpid())
	tmuxConfig := filepath.Join(root, "tmux.conf")
	if err := os.WriteFile(tmuxConfig, []byte("set -g status off\nset -g pane-base-index 1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	tmuxArgs := []string{"-L", server, "-f", tmuxConfig}
	foreign := append(append([]string{}, tmuxArgs...), "new-session", "-d", "-s", "foreign", "/bin/sleep", "60")
	if output, err := exec.Command(tmux, foreign...).CombinedOutput(); err != nil {
		t.Fatalf("create foreign isolated session: %v: %s", err, output)
	}
	t.Cleanup(func() { _ = exec.Command(tmux, "-L", server, "kill-server").Run() })

	spec := application.HostedPiLaunchSpec{AgentID: "real-agent", RuntimeID: "real-runtime", Incarnation: 1, TmuxSession: "ws-pi-real-agent", TmuxWindow: "pi", PiSessionDirectory: filepath.Join(root, "pi-sessions"), PiSessionName: "hosted-real-agent"}
	concrete := &hostedpi.Runtime{Config: hostedpi.Config{TmuxBinary: tmux, PiBinary: pi, BridgeExtension: bridge, DaemonEndpoint: socket, CredentialFile: credentialPath, ServerName: server, TmuxConfig: tmuxConfig, ProjectDirectory: repository, StateDirectory: filepath.Join(root, "state"), SessionID: bridgeSession.SessionID, GenerationID: bridgeSession.GenerationID, CallerIdentity: bridgeSession.Caller, TrustProject: true}}
	started := make(chan application.HostedPiOwnedProcess, 1)
	binding := application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, Lifetime: application.HostedPiLifetimeGlobalAgent, TmuxOwnership: application.HostedPiTmuxOwnershipExactSession, ControlBoundary: application.HostedPiControlDocumentedBridgeOnly, VisualizationBoundary: application.HostedPiVisualizationTmuxAttach, RuntimeID: spec.RuntimeID, Incarnation: spec.Incarnation}
	registration := application.RegisterAgent{AgentID: spec.AgentID, AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: spec.RuntimeID}, HostedPiRuntime: binding, AllowedCapability: []string{"observe", "hosted_bridge", "send", "ask", "control_abort", "control_shutdown"}, PhaseTwoOwned: true, Retention: "explicit", Recovery: "owned-binding-v1", Runtime: capturingRuntime{delegate: concrete, started: started}, LaunchSpec: spec}
	if err := daemon.RegisterAgent(context.Background(), registration); err != nil {
		t.Fatal(err)
	}
	var process application.HostedPiOwnedProcess
	select {
	case process = <-started:
	case <-time.After(10 * time.Second):
		t.Fatal("concrete hosted runtime did not start")
	}
	owned := process.Binding()
	if owned.TmuxSessionID == "" || owned.TmuxWindowID == "" || owned.TmuxServerPID < 1 || owned.TmuxServerStartToken == "" || owned.TmuxPane == "" || owned.PanePID < 1 || owned.ProcessStartToken == "" || owned.TTY == "" {
		t.Fatalf("incomplete exact ownership: %#v", owned)
	}
	records, err := filepath.Glob(filepath.Join(root, "state", "*.json"))
	if err != nil || len(records) != 1 {
		t.Fatalf("hosted binding record missing: %v %v", records, err)
	}
	if info, err := os.Stat(records[0]); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("hosted binding record is not 0600: %v", err)
	}
	if _, err := concrete.Start(context.Background(), spec); !errors.Is(err, hostedpi.ErrRuntimeAlreadyExists) {
		t.Fatalf("restart reconciliation did not fail closed: %v", err)
	}

	base := func(payload *subagentsv1.ListAgentsRequest) *subagentsv1.Envelope {
		return &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, SessionId: bridgeSession.SessionID, GenerationId: bridgeSession.GenerationID, CallerIdentity: bridgeSession.Caller, SessionCredential: credential, RequestId: fmt.Sprint(time.Now().UnixNano()), DeadlineUnixMillis: time.Now().Add(2 * time.Second).UnixMilli(), Payload: &subagentsv1.Envelope_ListAgentsRequest{ListAgentsRequest: payload}}
	}
	deadline := time.Now().Add(15 * time.Second)
	for {
		response := request(t, socket, base(&subagentsv1.ListAgentsRequest{}))
		agents := response.GetListAgentsResponse().Agents
		if len(agents) == 1 && agents[0].HostedPiRuntime.GetBridgeReady() {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("installed Pi bridge never became ready: %#v", response)
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err := exec.Command(tmux, "-L", server, "has-session", "-t", spec.TmuxSession).Run(); err != nil {
		t.Fatal("stable hosted tmux attach target does not exist")
	}

	smokeCredential := []byte(strings.Repeat("s", 32))
	smoke := application.OpenSession{SessionID: "real-smoke", GenerationID: "gateway", Caller: "hosted:smoke-source", Credential: smokeCredential, Capabilities: []string{"observe", "send", "ask"}, ExpiresAt: time.Now().Add(time.Hour)}
	if err := daemon.OpenSession(context.Background(), smoke); err != nil {
		t.Fatal(err)
	}
	smokeRequest := func(payload any, fence ...any) *subagentsv1.Envelope {
		envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, SessionId: smoke.SessionID, GenerationId: smoke.GenerationID, CallerIdentity: smoke.Caller, SessionCredential: smoke.Credential, RequestId: fmt.Sprint(time.Now().UnixNano()), DeadlineUnixMillis: time.Now().Add(2 * time.Second).UnixMilli()}
		if len(fence) == 2 {
			envelope.AgentHandle = fence[0].(string)
			envelope.AgentFence = fence[1].(uint64)
		}
		switch value := payload.(type) {
		case *subagentsv1.Envelope_ListAgentsRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_ResolveAgentRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_ActorMessageRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_AttachRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_SubscribeAgentRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_UnsubscribeAgentRequest:
			envelope.Payload = value
		default:
			t.Fatalf("unsupported real smoke payload %T", payload)
		}
		return request(t, socket, envelope)
	}
	if len(smokeRequest(&subagentsv1.Envelope_ListAgentsRequest{ListAgentsRequest: &subagentsv1.ListAgentsRequest{}}).GetListAgentsResponse().Agents) != 1 {
		t.Fatal("real smoke list failed")
	}
	if smokeRequest(&subagentsv1.Envelope_ResolveAgentRequest{ResolveAgentRequest: &subagentsv1.ResolveAgentRequest{AgentId: "real"}}).GetResolveAgentResponse().Agent.GetAgentId() != spec.AgentID {
		t.Fatal("real smoke resolve failed")
	}
	attached := smokeRequest(&subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: spec.AgentID, RequestedCapabilities: []string{"observe", "send", "ask"}}}).GetAttachResponse()
	if attached.AgentHandle == "" || attached.Fence == 0 {
		t.Fatal("real smoke attach failed")
	}
	for _, mode := range []subagentsv1.ActorMessageRequest_Mode{subagentsv1.ActorMessageRequest_MODE_TELL, subagentsv1.ActorMessageRequest_MODE_ASK} {
		result := smokeRequest(&subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: mode, Target: spec.AgentID, BoundedPayload: []byte("hosted smoke"), DedupeId: fmt.Sprintf("real-%d", mode), HopLimit: 8, ChainId: fmt.Sprintf("real-chain-%d", mode), SourceMutationSequence: uint64(mode)}}, attached.AgentHandle, attached.Fence).GetActorMessageResponse()
		if !result.Accepted || (mode == subagentsv1.ActorMessageRequest_MODE_ASK && result.Completed) {
			t.Fatalf("real smoke typed delivery admission failed: %#v", result)
		}
	}
	if !smokeRequest(&subagentsv1.Envelope_SubscribeAgentRequest{SubscribeAgentRequest: &subagentsv1.SubscribeAgentRequest{AgentId: spec.AgentID}}, attached.AgentHandle, attached.Fence).GetAgentOperationResponse().Completed {
		t.Fatal("real smoke subscribe failed")
	}
	if !smokeRequest(&subagentsv1.Envelope_UnsubscribeAgentRequest{UnsubscribeAgentRequest: &subagentsv1.UnsubscribeAgentRequest{AgentId: spec.AgentID}}, attached.AgentHandle, attached.Fence).GetAgentOperationResponse().Completed {
		t.Fatal("real smoke unsubscribe failed")
	}

	clientCredential := []byte(strings.Repeat("u", 32))
	client := application.OpenSession{SessionID: "real-client", GenerationID: "one", Caller: "human", Credential: clientCredential, Capabilities: []string{"observe"}, ExpiresAt: time.Now().Add(time.Hour)}
	if err := daemon.OpenSession(context.Background(), client); err != nil {
		t.Fatal(err)
	}
	if err := daemon.CloseSession(context.Background(), client.SessionID); err != nil {
		t.Fatal(err)
	}
	if err := exec.Command(tmux, "-L", server, "has-session", "-t", spec.TmuxSession).Run(); err != nil {
		t.Fatal("client disconnect stopped hosted Pi")
	}
	client.SessionID, client.GenerationID = "real-client-later", "two"
	if err := daemon.OpenSession(context.Background(), client); err != nil {
		t.Fatal(err)
	}

	stopCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := daemon.Stop(stopCtx); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	if err := exec.Command(tmux, "-L", server, "has-session", "-t", spec.TmuxSession).Run(); err == nil {
		t.Fatal("exact hosted tmux session survived cleanup")
	}
	if err := exec.Command(tmux, "-L", server, "has-session", "-t", "foreign").Run(); err != nil {
		t.Fatal("hosted cleanup destroyed foreign tmux session")
	}
}
