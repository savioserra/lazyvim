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
	localPort, remotePort := serviceFreePort(t), serviceFreePort(t)
	localRuntime, remoteRuntime := integrationRuntimes(t, localPort, remotePort)
	local := startIntegrationService(t, ctx, filepath.Join(root, "local"), localRuntime)
	remote := startIntegrationService(t, ctx, filepath.Join(root, "node-b"), remoteRuntime)
	_ = remote
	time.Sleep(time.Second)

	admin := application.OpenSession{Credential: local.adminCredential}
	client := openClientSession(t, local, admin)
	time.Sleep(50 * time.Millisecond)
	createEnvelope := local.dispatch(env(local, admin, &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: "ui_remote_qa", ProjectDirectory: filepath.Join(root, "project"), TrustProject: true, DisplayName: "Remote QA", Role: "qa", TargetNode: "node-b"}}, "create-qa-fixture", "", 0))
	created := createEnvelope.GetHostedAdminResponse()
	if created == nil || !created.Accepted || created.GetRuntime().GetState() == subagentsv1.HostedPiRuntimeBinding_STATE_UNSPECIFIED {
		t.Fatalf("remote fixture create failed: %#v err=%#v envelope=%#v", created, createEnvelope.GetProtocolError(), createEnvelope)
	}
	waitRemoteDeterminate(t, local, client, "ui_remote_qa")

	t.Run("targetNode remote create yields full remote hosted AgentActor reference", func(t *testing.T) {
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
		first := local.dispatch(env(local, admin, &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: "ui_remote_dup", ProjectDirectory: filepath.Join(root, "dup"), TrustProject: true, TargetNode: "node-b"}}, "dup-same", "", 0)).GetHostedAdminResponse()
		second := local.dispatch(env(local, admin, &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: "ui_remote_dup", ProjectDirectory: filepath.Join(root, "dup"), TrustProject: true, TargetNode: "node-b"}}, "dup-same", "", 0)).GetHostedAdminResponse()
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
	connectFakeBridge(t, remote, "ui_remote_qa")
	time.Sleep(50 * time.Millisecond)
	t.Run("attach then Tell and Ask cross nodes", func(t *testing.T) {
		tell := local.dispatch(env(local, client, &subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_TELL, Target: "ui_remote_qa", BoundedPayload: []byte("notify"), DedupeId: "tell-d", ChainId: "tell-c", HopLimit: 4, SourceMutationSequence: 1}}, "tell-1", handle, fence)).GetActorMessageResponse()
		if tell == nil || !tell.Accepted {
			t.Fatalf("tell failed: %#v", tell)
		}
		waitRemoteDeterminate(t, local, client, "ui_remote_qa")
		ask := askUntilDeterminate(t, local, client, handle, fence, &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_ASK, Target: "ui_remote_qa", BoundedPayload: []byte("question"), DedupeId: "ask-d", ChainId: "ask-c", HopLimit: 4, SourceMutationSequence: 2})
		if !ask.Accepted || ask.Completed {
			t.Fatalf("ask admission should be asynchronous: %#v", ask)
		}
		ackNextPrompt(t, remote, "ui_remote_qa", []byte("answer"))
	})

	t.Run("unified credit protocol completes remote ask with completion told back cross-node", func(t *testing.T) {
		waitRemoteDeterminate(t, local, client, "ui_remote_qa")
		// The remote tell exercises credit grant -> ActorTask -> acceptance on
		// the remote node; the ask additionally returns the acknowledged
		// terminal through the completion Tell back to the source node. The
		// completion replay must use the same request identity.
		unified := &subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_ASK, Target: "ui_remote_qa", BoundedPayload: []byte("unified question"), DedupeId: "unified-d", ChainId: "unified-c", HopLimit: 4, SourceMutationSequence: 3}}
		ask := local.dispatch(env(local, client, unified, "unified-ask-1", handle, fence)).GetActorMessageResponse()
		if ask == nil || !ask.Accepted || ask.Completed {
			t.Fatalf("unified remote ask admission should be asynchronous: %#v", ask)
		}
		ackNextPrompt(t, remote, "ui_remote_qa", []byte("unified answer"))
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			completed := local.dispatch(env(local, client, unified, "unified-ask-1", handle, fence)).GetActorMessageResponse()
			if completed != nil && completed.Accepted && completed.Completed {
				if string(completed.BoundedResult) != "unified answer" {
					t.Fatalf("unified remote ask completion carried the wrong terminal: %#v", completed)
				}
				return
			}
			time.Sleep(25 * time.Millisecond)
		}
		t.Fatal("unified remote ask completion never reached the source node")
	})

	t.Run("remote duplicate actor message is idempotent", func(t *testing.T) {
		waitRemoteDeterminate(t, local, client, "ui_remote_qa")
		duplicate := &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_TELL, Target: "ui_remote_qa", BoundedPayload: []byte("dup notify"), DedupeId: "dup-d", ChainId: "dup-c", HopLimit: 4, SourceMutationSequence: 4}
		first := local.dispatch(env(local, client, &subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: duplicate}, "dup-1", handle, fence)).GetActorMessageResponse()
		second := local.dispatch(env(local, client, &subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: duplicate}, "dup-1", handle, fence)).GetActorMessageResponse()
		if first == nil || second == nil || !first.Accepted || !second.Accepted {
			t.Fatalf("duplicate remote tell not idempotent: %#v %#v", first, second)
		}
		if first.Reason != "stored_pending_credit" || second.Completed || second.Reason != first.Reason {
			t.Fatalf("duplicate remote tell must replay the stored pending credit receipt: %#v %#v", first, second)
		}
		collision := local.dispatch(env(local, client, &subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_TELL, Target: "ui_remote_qa", BoundedPayload: []byte("changed dup notify"), DedupeId: "dup-d", ChainId: "dup-c", HopLimit: 4, SourceMutationSequence: 4}}, "dup-collision", handle, fence)).GetActorMessageResponse()
		if collision == nil || collision.Accepted || collision.Reason != "source mutation sequence collision" {
			t.Fatalf("changed duplicate did not fail closed: %#v", collision)
		}
	})

	t.Run("concurrent remote duplicate actor messages converge", func(t *testing.T) {
		waitRemoteDeterminate(t, local, client, "ui_remote_qa")
		duplicate := &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_TELL, Target: "ui_remote_qa", BoundedPayload: []byte("concurrent dup notify"), DedupeId: "dup-concurrent-d", ChainId: "dup-concurrent-c", HopLimit: 4, SourceMutationSequence: 5}
		responses := make(chan *subagentsv1.ActorMessageResponse, 2)
		for i := 0; i < 2; i++ {
			go func(index int) {
				_ = index
				responses <- local.dispatch(env(local, client, &subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: duplicate}, "dup-concurrent", handle, fence)).GetActorMessageResponse()
			}(i)
		}
		first, second := <-responses, <-responses
		if first == nil || second == nil || !first.Accepted || !second.Accepted || first.Reason != "stored_pending_credit" || second.Reason != first.Reason {
			t.Fatalf("concurrent duplicate remote tell did not converge: %#v %#v", first, second)
		}
	})

	t.Run("stale remote node fails deterministically without host or port leak", func(t *testing.T) {
		waitRemoteDeterminate(t, local, client, "ui_remote_qa")
		// Poison the public directory entry for a synthetic remote agent so the
		// authority itself is unreachable: resolution must fail closed with a
		// fixed reason and never echo host or port details.
		local.actorPlane.PublicNodes["gone"] = application.PublicNode{Identity: "gone", Host: "127.0.0.1", Port: serviceFreePort(t)}
		value, err := local.system.NoSender().Ask(context.Background(), local.publicDirectory, &application.CreatePublicAgent{AgentID: "stale_remote", ActorName: application.HostedPlacementAuthorityName("gone"), Placement: application.PublicAgentPlacement{NodeIdentity: "gone"}, Reference: application.AgentReference{AgentID: "stale_remote", LifecycleRevision: 1, AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: "stale-runtime"}}}, 2*time.Second)
		if err != nil || value == nil {
			t.Fatalf("stale directory record creation failed: %v %#v", err, value)
		}
		staleEnvelope := local.dispatch(env(local, client, &subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_TELL, Target: "stale_remote", BoundedPayload: []byte("stale"), DedupeId: "stale-d", ChainId: "stale-c", HopLimit: 4, SourceMutationSequence: 6}}, "stale-1", handle, fence))
		if failed := staleEnvelope.GetActorMessageResponse(); failed != nil && failed.Accepted {
			t.Fatalf("stale remote target was not rejected: %#v", failed)
		} else if staleEnvelope.GetProtocolError() == nil {
			t.Fatalf("stale remote target produced neither denial nor protocol error: %#v", staleEnvelope)
		}
		encoded := fmt.Sprintf("%#v", staleEnvelope)
		for _, forbidden := range []string{"127.0.0.1", ":9", "host:", "port"} {
			if strings.Contains(encoded, forbidden) {
				t.Fatalf("stale remote failure leaked %s: %s", forbidden, encoded)
			}
		}
	})

	t.Run("typed prompt lifecycle reaches remote bridge correlation boundary", func(t *testing.T) {
		waitRemoteDeterminate(t, local, client, "ui_remote_qa")
		go ackNextPrompt(t, remote, "ui_remote_qa", []byte("life-answer"))
		// Unified actor messaging advanced the tell/ask mutations in the
		// per-source actor task scope, so this prompt lifecycle is the first
		// client-session-scope mutation on the remote target.
		started := local.dispatch(env(local, client, &subagentsv1.Envelope_TaskLifecycleRequest{TaskLifecycleRequest: &subagentsv1.TaskLifecycleRequest{Operation: subagentsv1.TaskLifecycleRequest_OPERATION_START, LifecycleId: "life-1", Target: "ui_remote_qa", BoundedPrompt: []byte("do work"), DedupeId: "life-d", ChainId: "life-c", HopLimit: 4, SourceMutationSequence: 1}}, "life-req", handle, fence)).GetTaskLifecycleResponse()
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
		resp := local.dispatch(env(local, bad, &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: "denied", ProjectDirectory: filepath.Join(root, "denied"), TargetNode: "node-b"}}, "denied", "", 0)).GetProtocolError()
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
		if local.actorPlane == nil || local.actorPlane.Cluster == nil {
			t.Skip("cluster PubSub availability replay requires GoAkt cluster membership")
		}
		_ = local.Stop(context.Background())
		fresh := startIntegrationService(t, ctx, filepath.Join(root, "fresh"), localRuntime)
		fresh.adminCredential = local.adminCredential
		if err := fresh.OpenSession(ctx, client); err != nil {
			t.Fatal(err)
		}
		_ = fresh.system.NoSender().Tell(ctx, fresh.publicDirectory, &application.StageSession{Session: client, Registry: application.AgentRegistry})
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			listed := fresh.dispatch(env(fresh, client, &subagentsv1.Envelope_ListAgentsRequest{ListAgentsRequest: &subagentsv1.ListAgentsRequest{}}, "fresh-list", "", 0)).GetListAgentsResponse()
			if listed != nil && hasAgent(listed.Agents, "ui_remote_qa") {
				return
			}
			time.Sleep(50 * time.Millisecond)
		}
		listed := fresh.dispatch(env(fresh, client, &subagentsv1.Envelope_ListAgentsRequest{ListAgentsRequest: &subagentsv1.ListAgentsRequest{}}, "fresh-list-final", "", 0)).GetListAgentsResponse()
		if listed == nil || !hasAgent(listed.Agents, "ui_remote_qa") {
			t.Fatalf("topic snapshot after restart missing remote: %#v", listed)
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

func integrationRuntimes(t *testing.T, localPort, remotePort int) (*remoting.Runtime, *remoting.Runtime) {
	t.Helper()
	_, caKey, ca := placementCA(t)
	roots := x509.NewCertPool()
	roots.AddCert(ca)
	localKey, localDER := placementLeaf(t, ca, caKey, "spiffe://workstation/subagents/local")
	remoteKey, remoteDER := placementLeaf(t, ca, caKey, "spiffe://workstation/subagents/node-b")
	allowed := map[string]struct{}{"spiffe://workstation/subagents/local": {}, "spiffe://workstation/subagents/node-b": {}}
	local := &remoting.PlacementTrust{Signer: localKey, CertificateDER: [][]byte{localDER}, Roots: roots, AllowedURIs: allowed}
	remote := &remoting.PlacementTrust{Signer: remoteKey, CertificateDER: [][]byte{remoteDER}, Roots: roots, AllowedURIs: allowed}
	return integrationRuntime("local", localPort, remotePort, local), integrationRuntime("node-b", remotePort, localPort, remote)
}
func integrationRuntime(id string, port, peerPort int, trust *remoting.PlacementTrust) *remoting.Runtime {
	peer := "node-b"
	if id == "node-b" {
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
func waitRemoteDeterminate(t *testing.T, s *Service, client application.OpenSession, id string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		status := s.dispatch(env(s, client, &subagentsv1.Envelope_ListAgentsRequest{ListAgentsRequest: &subagentsv1.ListAgentsRequest{}}, "status"+time.Now().String(), "", 0)).GetListAgentsResponse()
		if status != nil && hasAgent(status.Agents, id) {
			time.Sleep(25 * time.Millisecond)
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("remote actor never became determinate")
}

func askUntilDeterminate(t *testing.T, s *Service, client application.OpenSession, handle string, fence uint64, logical *subagentsv1.ActorMessageRequest) *subagentsv1.ActorMessageResponse {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	attempt := 0
	for time.Now().Before(deadline) {
		attempt++
		response := s.dispatch(env(s, client, &subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: logical}, fmt.Sprintf("ask-retry-%d", attempt), handle, fence)).GetActorMessageResponse()
		if response != nil && response.Reason == "durable persistence is busy" && !response.Accepted {
			time.Sleep(25 * time.Millisecond)
			continue
		}
		return response
	}
	t.Fatalf("ask remained indeterminate")
	return nil
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
					_ = s.dispatch(env(s, bridge.session, &subagentsv1.Envelope_BridgeDeliveryAckRequest{BridgeDeliveryAckRequest: identityBridgeAck(id, record.Binding.RuntimeID, "fake-pi", record.Binding.Incarnation, d, true, result)}, "ack"+time.Now().String(), bridge.handle, bridge.fence))
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
