package service

import (
	"context"
	"crypto/x509"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/hostedpi"
	"github.com/savioserra/lazyvim/services/subagents/internal/remoting"
	"github.com/tochemey/goakt/v4/remote"
)

type integrationBridgeSession struct {
	session application.OpenSession
	handle  string
	fence   uint64
}

var integrationBridgeSessions sync.Map

func TestRemoteHostedOrdinaryServicePath(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	_ = os.Chmod(root, 0o700)
	for _, name := range []string{"project", "dup", "missing", "denied"} {
		_ = os.Mkdir(filepath.Join(root, name), 0o700)
	}
	localPort, vpsPort := serviceFreePort(t), serviceFreePort(t)
	localRuntime, vpsRuntime := integrationRuntimes(t, localPort, vpsPort)
	local := startIntegrationService(t, ctx, filepath.Join(root, "local"), localRuntime)
	vps := startIntegrationService(t, ctx, filepath.Join(root, "vps"), vpsRuntime)
	_ = vps
	time.Sleep(time.Second)

	admin := application.OpenSession{Credential: local.adminCredential}
	client := openClientSession(t, local, admin)
	time.Sleep(50 * time.Millisecond)

	t.Run("targetNode remote create yields full remote hosted AgentActor reference", func(t *testing.T) {
		createEnvelope := local.dispatch(env(local, admin, &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: "ui_remote_qa", ProjectDirectory: filepath.Join(root, "project"), TrustProject: true, DisplayName: "Remote QA", Role: "qa", TargetNode: "vps"}}, "create-1", "", 0))
		created := createEnvelope.GetHostedAdminResponse()
		if created == nil || !created.Accepted || created.GetRuntime().GetState() == subagentsv1.HostedPiRuntimeBinding_STATE_UNSPECIFIED {
			t.Fatalf("remote create failed: %#v err=%#v envelope=%#v", created, createEnvelope.GetProtocolError(), createEnvelope)
		}
		resolved := resolveAgent(t, local, client, "ui_remote_qa")
		if resolved.Agent.GetAgentId() != "ui_remote_qa" || resolved.Agent.GetDisplayName() != "Remote QA" || resolved.Agent.GetHostedPiRuntime().GetAggregateId() != "ui_remote_qa" {
			t.Fatalf("remote metadata not public/stable: %#v", resolved.Agent)
		}
		encoded := fmt.Sprintf("%#v", resolved.Agent)
		for _, forbidden := range []string{"127.0.0.1", "172", "Credential", "Signature", "Certificate", "TmuxSessionId"} {
			if contains(encoded, forbidden) {
				t.Fatalf("public resolve leaked %s: %s", forbidden, encoded)
			}
		}
	})

	t.Run("duplicate idempotency", func(t *testing.T) {
		first := local.dispatch(env(local, admin, &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: "ui_remote_dup", ProjectDirectory: filepath.Join(root, "dup"), TrustProject: true, TargetNode: "vps"}}, "dup-same", "", 0)).GetHostedAdminResponse()
		second := local.dispatch(env(local, admin, &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: "ui_remote_dup", ProjectDirectory: filepath.Join(root, "dup"), TrustProject: true, TargetNode: "vps"}}, "dup-same", "", 0)).GetHostedAdminResponse()
		if first == nil || second == nil || !first.Accepted || !second.Accepted || first.AgentId != second.AgentId {
			t.Fatalf("duplicate not idempotent: %#v %#v", first, second)
		}
	})

	t.Run("local list resolve sees remote metadata", func(t *testing.T) {
		listed := local.dispatch(env(local, client, &subagentsv1.Envelope_ListAgentsRequest{ListAgentsRequest: &subagentsv1.ListAgentsRequest{}}, "list-1", "", 0)).GetListAgentsResponse()
		if listed == nil || !hasAgent(listed.Agents, "ui_remote_qa") {
			t.Fatalf("list missing remote: %#v", listed)
		}
		_ = resolveAgent(t, local, client, "ui_remote_qa")
	})

	handle, fence := attachRemote(t, local, client, "ui_remote_qa")
	connectFakeBridge(t, vps, "ui_remote_qa")
	time.Sleep(50 * time.Millisecond)
	t.Run("attach then Tell and Ask cross nodes", func(t *testing.T) {
		tell := local.dispatch(env(local, client, &subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_TELL, Target: "ui_remote_qa", BoundedPayload: []byte("notify"), DedupeId: "tell-d", ChainId: "tell-c", HopLimit: 4, SourceMutationSequence: 1}}, "tell-1", handle, fence)).GetActorMessageResponse()
		if tell == nil || !tell.Accepted {
			t.Fatalf("tell failed: %#v", tell)
		}
		time.Sleep(500 * time.Millisecond)
		go ackNextPrompt(t, vps, "ui_remote_qa", []byte("answer"))
		ask := local.dispatch(env(local, client, &subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_ASK, Target: "ui_remote_qa", BoundedPayload: []byte("question"), DedupeId: "ask-d", ChainId: "ask-c", HopLimit: 4, SourceMutationSequence: 2}}, "ask-1", handle, fence)).GetActorMessageResponse()
		if ask == nil || !ask.Accepted || !ask.Completed || string(ask.BoundedResult) != "answer" {
			t.Fatalf("ask failed: %#v", ask)
		}
	})

	t.Run("typed prompt lifecycle reaches remote bridge correlation boundary", func(t *testing.T) {
		time.Sleep(500 * time.Millisecond)
		go ackNextPrompt(t, vps, "ui_remote_qa", []byte("life-answer"))
		started := local.dispatch(env(local, client, &subagentsv1.Envelope_TaskLifecycleRequest{TaskLifecycleRequest: &subagentsv1.TaskLifecycleRequest{Operation: subagentsv1.TaskLifecycleRequest_OPERATION_START, LifecycleId: "life-1", Target: "ui_remote_qa", BoundedPrompt: []byte("do work"), DedupeId: "life-d", ChainId: "life-c", HopLimit: 4, SourceMutationSequence: 3}}, "life-req", handle, fence)).GetTaskLifecycleResponse()
		if started == nil || !started.Accepted || started.LifecycleId != "life-1" {
			t.Fatalf("lifecycle start failed: %#v", started)
		}
		waited := local.dispatch(env(local, client, &subagentsv1.Envelope_TaskLifecycleRequest{TaskLifecycleRequest: &subagentsv1.TaskLifecycleRequest{Operation: subagentsv1.TaskLifecycleRequest_OPERATION_WAIT, LifecycleId: "life-1", Target: "ui_remote_qa", WaitMillis: 1000}}, "life-wait", handle, fence)).GetTaskLifecycleResponse()
		if waited == nil || !waited.Terminal || string(waited.BoundedAnswer) != "life-answer" {
			t.Fatalf("lifecycle wait failed: %#v", waited)
		}
	})

	t.Run("unauthorized local admin denied before remote traffic", func(t *testing.T) {
		bad := application.OpenSession{Credential: []byte("bad-bad-bad-bad-bad-bad-bad-bad!")}
		resp := local.dispatch(env(local, bad, &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: "denied", ProjectDirectory: filepath.Join(root, "denied"), TargetNode: "vps"}}, "denied", "", 0)).GetProtocolError()
		if resp == nil {
			t.Fatal("unauthorized admin was not denied")
		}
	})

	t.Run("unavailable remote bounded failure", func(t *testing.T) {
		local.actorPlane.PublicNodes["gone"] = application.PublicNode{Identity: "gone", Host: "127.0.0.1", Port: serviceFreePort(t)}
		resp := local.dispatch(env(local, admin, &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: "missing", ProjectDirectory: filepath.Join(root, "missing"), TargetNode: "gone"}}, "gone", "", 0)).GetProtocolError()
		if resp == nil {
			t.Fatal("unavailable peer did not fail bounded")
		}
	})

	t.Run("origin service restart reconciles remote record", func(t *testing.T) {
		_ = local.Stop(context.Background())
		fresh := startIntegrationService(t, ctx, filepath.Join(root, "fresh"), localRuntime)
		fresh.adminCredential = local.adminCredential
		if err := fresh.OpenSession(ctx, client); err != nil {
			t.Fatal(err)
		}
		_ = fresh.system.NoSender().Tell(ctx, fresh.publicDirectory, &application.StageSession{Session: client, Registry: application.AgentRegistry})
		fresh.reconcilePublicHostedPeers(ctx)
		time.Sleep(50 * time.Millisecond)
		listed := fresh.dispatch(env(fresh, client, &subagentsv1.Envelope_ListAgentsRequest{ListAgentsRequest: &subagentsv1.ListAgentsRequest{}}, "fresh-list", "", 0)).GetListAgentsResponse()
		if listed == nil || !hasAgent(listed.Agents, "ui_remote_qa") {
			t.Fatalf("restart reconcile missing remote: %#v", listed)
		}
	})
}

func startIntegrationService(t *testing.T, ctx context.Context, root string, runtime *remoting.Runtime) *Service {
	t.Helper()
	for _, d := range []string{root, filepath.Join(root, "state"), filepath.Join(root, "sessions"), filepath.Join(root, "credentials"), filepath.Join(root, "project")} {
		_ = os.MkdirAll(d, 0o700)
	}
	listener, err := net.Listen("unix", filepath.Join(root, "control.sock"))
	if err != nil {
		t.Fatal(err)
	}
	process := &clientProcess{binding: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, TmuxSessionID: "$x", TmuxWindowID: "@x", TmuxPane: "%x", PanePID: 42, ProcessStartToken: "start", TTY: "/dev/pts/1"}, done: make(chan error, 1)}
	svc, err := startWithListener(ctx, listener, HostedAdminConfig{Enabled: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge", StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: filepath.Join(root, "admin.json"), DefaultProjectDirectory: filepath.Join(root, "project"), TrustProject: true, RuntimeFactory: func(hostedpi.Config) application.HostedPiRuntime { return clientRuntime{process: process} }}, listener.Addr().String(), runtime)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = svc.Stop(context.Background()) })
	return svc
}

func integrationRuntimes(t *testing.T, localPort, vpsPort int) (*remoting.Runtime, *remoting.Runtime) {
	t.Helper()
	_, caKey, ca := placementCA(t)
	roots := x509.NewCertPool()
	roots.AddCert(ca)
	localKey, localDER := placementLeaf(t, ca, caKey, "spiffe://workstation/subagents/local")
	vpsKey, vpsDER := placementLeaf(t, ca, caKey, "spiffe://workstation/subagents/vps")
	allowed := map[string]struct{}{"spiffe://workstation/subagents/local": {}, "spiffe://workstation/subagents/vps": {}}
	local := &remoting.PlacementTrust{Signer: localKey, CertificateDER: [][]byte{localDER}, Roots: roots, AllowedURIs: allowed}
	vps := &remoting.PlacementTrust{Signer: vpsKey, CertificateDER: [][]byte{vpsDER}, Roots: roots, AllowedURIs: allowed}
	return integrationRuntime("local", localPort, vpsPort, local), integrationRuntime("vps", vpsPort, localPort, vps)
}
func integrationRuntime(id string, port, peerPort int, trust *remoting.PlacementTrust) *remoting.Runtime {
	peer := "vps"
	if id == "vps" {
		peer = "local"
	}
	return &remoting.Runtime{NodeIdentity: id, MTLSIdentity: "spiffe://workstation/subagents/" + id, Remote: remote.NewConfig("127.0.0.1", port, remoting.PublicAgentSerializers()...), PublicNodes: map[string]application.PublicNode{id: {Identity: id, Host: "127.0.0.1", Port: port}, peer: {Identity: peer, Host: "127.0.0.1", Port: peerPort}}, Trust: trust}
}
func serviceFreePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}
func env(s *Service, session application.OpenSession, payload any, requestID, handle string, fence uint64) *subagentsv1.Envelope {
	e := &subagentsv1.Envelope{ProtocolMajor: 1, ProtocolMinor: 1, RequestId: requestID, DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli(), Sequence: 1, SessionId: session.SessionID, GenerationId: session.GenerationID, CallerIdentity: session.Caller, SessionCredential: session.Credential, AgentHandle: handle, AgentFence: fence}
	switch v := payload.(type) {
	case *subagentsv1.Envelope_HostedAdminRequest:
		e.Payload = v
	case *subagentsv1.Envelope_ClientSessionRequest:
		e.Payload = v
	case *subagentsv1.Envelope_ListAgentsRequest:
		e.Payload = v
	case *subagentsv1.Envelope_ResolveAgentRequest:
		e.Payload = v
	case *subagentsv1.Envelope_AttachRequest:
		e.Payload = v
	case *subagentsv1.Envelope_BridgeConnectRequest:
		e.Payload = v
	case *subagentsv1.Envelope_BridgeLifecycleRequest:
		e.Payload = v
	case *subagentsv1.Envelope_PromptTaskRequest:
		e.Payload = v
	case *subagentsv1.Envelope_TaskLifecycleRequest:
		e.Payload = v
	case *subagentsv1.Envelope_ActorMessageRequest:
		e.Payload = v
	case *subagentsv1.Envelope_BridgePollRequest:
		e.Payload = v
	case *subagentsv1.Envelope_BridgeDeliveryAckRequest:
		e.Payload = v
	default:
		panic(fmt.Sprintf("bad payload %T", payload))
	}
	return e
}
func openClientSession(t *testing.T, s *Service, admin application.OpenSession) application.OpenSession {
	t.Helper()
	opened := s.dispatch(env(s, admin, &subagentsv1.Envelope_ClientSessionRequest{ClientSessionRequest: &subagentsv1.ClientSessionRequest{Operation: subagentsv1.ClientSessionRequest_OPERATION_OPEN}}, "open", "", 0)).GetClientSessionResponse()
	if opened == nil || !opened.Accepted {
		t.Fatalf("open failed %#v", opened)
	}
	return application.OpenSession{SessionID: opened.SessionId, GenerationID: opened.GenerationId, Caller: opened.CallerIdentity, Credential: opened.SessionCredential, Capabilities: []string{"observe", "send", "ask", "prompt", "control_abort", "control_shutdown"}, ExpiresAt: time.UnixMilli(opened.ExpiresUnixMillis), Persistent: true}
}
func resolveAgent(t *testing.T, s *Service, client application.OpenSession, id string) *subagentsv1.ResolveAgentResponse {
	t.Helper()
	r := s.dispatch(env(s, client, &subagentsv1.Envelope_ResolveAgentRequest{ResolveAgentRequest: &subagentsv1.ResolveAgentRequest{AgentId: id}}, "resolve-"+id, "", 0)).GetResolveAgentResponse()
	if r == nil || r.Agent == nil {
		t.Fatalf("resolve failed %#v", r)
	}
	return r
}
func hasAgent(list []*subagentsv1.AgentReference, id string) bool {
	for _, a := range list {
		if a.AgentId == id {
			return true
		}
	}
	return false
}
func attachRemote(t *testing.T, s *Service, client application.OpenSession, id string) (string, uint64) {
	t.Helper()
	var a *subagentsv1.AttachResponse
	for i := 0; i < 20; i++ {
		attachEnv := s.dispatch(env(s, client, &subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: id, RequestedCapabilities: []string{"observe", "send", "ask", "prompt"}}}, fmt.Sprintf("attach-%s-%d", id, i), "", 0))
		if err := attachEnv.GetProtocolError(); err != nil {
			t.Logf("attach protocol error: %s", err.Message)
		}
		a = attachEnv.GetAttachResponse()
		if a != nil && a.Status == subagentsv1.AttachResponse_STATUS_COMPLETED {
			return a.AgentHandle, a.Fence
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("attach failed %#v", a)
	return "", 0
}
func connectFakeBridge(t *testing.T, s *Service, id string) {
	t.Helper()
	s.hostedMu.Lock()
	meta := s.hostedRegistrations[id]
	s.hostedMu.Unlock()
	records, err := s.durableStore.LoadAll(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var record application.DurableHostedRecord
	for _, r := range records {
		if r.AgentID == id {
			record = r
		}
	}
	if record.AgentID == "" {
		t.Fatalf("durable record missing for %s", id)
	}
	cred, err := hostedpi.ReadCredentialFile(meta.credentialFile)
	if err != nil {
		t.Fatal(err)
	}
	sess := application.OpenSession{SessionID: record.Session.SessionID, GenerationID: record.Session.GenerationID, Caller: record.Session.Caller, Credential: cred}
	attached := s.dispatch(env(s, sess, &subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: id, RequestedCapabilities: []string{"hosted_bridge", "observe", "send", "ask", "prompt"}}}, "bridge-attach", "", 0)).GetAttachResponse()
	if attached == nil || attached.Status != subagentsv1.AttachResponse_STATUS_COMPLETED {
		t.Fatalf("bridge attach failed %#v", attached)
	}
	connected := s.dispatch(env(s, sess, &subagentsv1.Envelope_BridgeConnectRequest{BridgeConnectRequest: &subagentsv1.BridgeConnectRequest{AgentId: id, RuntimeId: record.Binding.RuntimeID, Incarnation: record.Binding.Incarnation, PiSessionId: "fake-pi"}}, "bridge-connect", attached.AgentHandle, attached.Fence)).GetBridgeConnectResponse()
	if connected == nil || !connected.Accepted {
		t.Fatalf("bridge connect failed %#v", connected)
	}
	life := s.dispatch(env(s, sess, &subagentsv1.Envelope_BridgeLifecycleRequest{BridgeLifecycleRequest: &subagentsv1.BridgeLifecycleRequest{AgentId: id, RuntimeId: record.Binding.RuntimeID, Incarnation: record.Binding.Incarnation, Event: subagentsv1.BridgeLifecycleRequest_EVENT_READY}}, "bridge-ready", connected.AgentHandle, connected.Fence)).GetBridgeLifecycleResponse()
	if life == nil || !life.Accepted {
		t.Fatalf("bridge ready failed %#v", life)
	}
	integrationBridgeSessions.Store(s, integrationBridgeSession{session: sess, handle: connected.AgentHandle, fence: connected.Fence})
}
func ackNextPrompt(t *testing.T, s *Service, id string, answer []byte) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		records, _ := s.durableStore.LoadAll(context.Background())
		var record application.DurableHostedRecord
		for _, r := range records {
			if r.AgentID == id {
				record = r
			}
		}
		if record.AgentID != "" {
			stored, ok := integrationBridgeSessions.Load(s)
			if !ok {
				t.Errorf("bridge session missing")
				return
			}
			bridge := stored.(integrationBridgeSession)
			poll := s.dispatch(env(s, bridge.session, &subagentsv1.Envelope_BridgePollRequest{BridgePollRequest: &subagentsv1.BridgePollRequest{AgentId: id, MaxItems: 8}}, "poll"+time.Now().String(), bridge.handle, bridge.fence)).GetBridgePollResponse()
			if poll != nil && len(poll.Deliveries) > 0 {
				for _, d := range poll.Deliveries {
					result := []byte(nil)
					if d.Kind == subagentsv1.BridgeDelivery_KIND_PROMPT {
						result = answer
					}
					_ = s.dispatch(env(s, bridge.session, &subagentsv1.Envelope_BridgeDeliveryAckRequest{BridgeDeliveryAckRequest: &subagentsv1.BridgeDeliveryAckRequest{AgentId: id, Sequence: d.Sequence, DedupeId: d.DedupeId, Delivered: true, BoundedResult: result}}, "ack"+time.Now().String(), bridge.handle, bridge.fence))
					if d.Kind == subagentsv1.BridgeDelivery_KIND_PROMPT {
						return
					}
				}
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Errorf("no prompt delivery to ack")
}
func contains(s, sub string) bool { return strings.Contains(s, sub) }
