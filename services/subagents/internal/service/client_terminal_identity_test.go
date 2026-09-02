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
	durablestate "github.com/savioserra/lazyvim/services/subagents/internal/state"
)

// terminalIdentityHarness boots one dispatch-level daemon with the hosted admin
// surface enabled but no hosted runtime processes.
func terminalIdentityHarness(t *testing.T) (*Service, func()) {
	t.Helper()
	root := t.TempDir()
	_ = os.Chmod(root, 0o700)
	listener, err := net.Listen("unix", filepath.Join(root, "control.sock"))
	if err != nil {
		t.Fatal(err)
	}
	config := HostedAdminConfig{Enabled: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge", StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: filepath.Join(root, "admin.json"), DefaultProjectDirectory: root, TrustProject: true}
	daemon, err := startWithListener(context.Background(), listener, config, listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	return daemon, func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	}
}

func terminalIdentityOpen(t *testing.T, daemon *Service, identity string) *subagentsv1.ClientSessionResponse {
	t.Helper()
	envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: time.Now().String(), DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli(), SessionCredential: daemon.adminCredential, Payload: &subagentsv1.Envelope_ClientSessionRequest{ClientSessionRequest: &subagentsv1.ClientSessionRequest{Operation: subagentsv1.ClientSessionRequest_OPERATION_OPEN, TerminalIdentity: identity}}}
	response := daemon.dispatch(envelope).GetClientSessionResponse()
	if response == nil {
		t.Fatalf("client session response missing for identity %q", identity)
	}
	return response
}

func TestClientSessionOpenReturnsStableTerminalActorMessageHighWater(t *testing.T) {
	daemon, stop := terminalIdentityHarness(t)
	defer stop()

	agentID := "client:high-water"
	binding := application.InactiveHostedPiRuntimeBinding()
	durable := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, OwnerUID: os.Getuid(), AgentID: agentID, AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: agentID}, AllowedCapabilities: []string{"observe", "send", "ask", "prompt", "control_abort", "control_shutdown"}, Retention: "bounded", Recovery: "terminal-reattach", Binding: binding, AgentState: application.DurableAgentState{SourceOutbox: []application.DurableActorTaskOutboxItem{{TaskID: "retained-task", SourceMutationSequence: 10, Deadline: time.Now().Add(time.Hour)}}}}
	registered := make(chan application.RegisterAgentResult, 1)
	registration := application.RegisterAgent{AgentID: agentID, Role: "TERMINAL PI", DisplayName: "TERMINAL PI", AuthorityBinding: durable.AuthorityBinding, HostedPiRuntime: binding, AllowedCapability: append([]string(nil), durable.AllowedCapabilities...), Retention: durable.Retention, Recovery: durable.Recovery, PersistencePID: daemon.persistencePID, PersistenceSupervisor: daemon.persistenceSupervisor, DurableRecord: &durable}
	if err := daemon.system.NoSender().Tell(context.Background(), daemon.agentRegistry, &application.CoordinateAgentRegistration{OperationID: "terminal-high-water", Registration: registration, Result: registered}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-registered:
		if !result.Created {
			t.Fatalf("terminal registration failed: %#v", result)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("terminal registration timed out")
	}

	opened := terminalIdentityOpen(t, daemon, "high-water")
	if !opened.Accepted || opened.ActorMessageHighWater != 10 {
		t.Fatalf("client OPEN did not return retained terminal high-water: %#v", opened)
	}
}

func terminalIdentityList(t *testing.T, daemon *Service, session application.OpenSession) []*subagentsv1.AgentReference {
	t.Helper()
	envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: time.Now().String(), DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli(), SessionId: session.SessionID, GenerationId: session.GenerationID, CallerIdentity: session.Caller, SessionCredential: session.Credential, Payload: &subagentsv1.Envelope_ListAgentsRequest{ListAgentsRequest: &subagentsv1.ListAgentsRequest{}}}
	listed := daemon.dispatch(envelope).GetListAgentsResponse()
	if listed == nil {
		t.Fatal("list agents response missing")
	}
	return listed.Agents
}

// TestClientTerminalIdentityReattachesAndDrainsAcrossReopens covers the churn
// incident: a second OPEN with the same terminal identity must reuse the SAME
// terminal AgentActor (one durable agent, stable principal) and the reply-drain
// registered for the new session must flush completions retained by that agent
// during the previous session, instead of stranding them in an orphaned actor.
func TestClientTerminalIdentityReattachesAndDrainsAcrossReopens(t *testing.T) {
	daemon, stop := terminalIdentityHarness(t)
	defer stop()

	first := terminalIdentityOpen(t, daemon, "term-echo")
	if !first.Accepted || first.CallerIdentity != "client:term-echo" {
		t.Fatalf("stable identity open failed: %#v", first)
	}
	if err := daemon.ensureTerminalAgent(context.Background(), "client:term-echo"); err != nil {
		t.Fatalf("terminal agent registration failed: %v", err)
	}
	value, err := daemon.system.NoSender().Ask(context.Background(), daemon.agentRegistry, &application.ResolveAgentControl{AgentID: "client:term-echo"}, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	resolved, ok := value.(*application.AgentControlPID)
	if !ok || !resolved.Found || resolved.PID == nil {
		t.Fatalf("terminal agent missing after registration: %#v", value)
	}
	if err := daemon.system.NoSender().Tell(context.Background(), resolved.PID, &application.ActorTaskCompleted{CompletionKey: "completion-echo", OriginalRequestID: "request-echo", DedupeID: "dedupe-echo", ChainID: "chain-echo", SourceMutationSequence: 1, Terminal: application.BridgeIntentResult{Accepted: true, Completed: true, Result: []byte("orphaned answer")}, Source: application.CommunicationPeer{StableID: "alpha"}, Target: application.CommunicationPeer{StableID: "client:term-echo"}, Kind: application.BridgeDeliveryNotification}); err != nil {
		t.Fatal(err)
	}

	// Simulate the churn trigger: the first session closes, a fresh OPEN runs.
	closeEnvelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: time.Now().String(), DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli(), SessionId: first.SessionId, GenerationId: first.GenerationId, CallerIdentity: first.CallerIdentity, SessionCredential: first.SessionCredential, Payload: &subagentsv1.Envelope_ClientSessionRequest{ClientSessionRequest: &subagentsv1.ClientSessionRequest{Operation: subagentsv1.ClientSessionRequest_OPERATION_CLOSE}}}
	if closed := daemon.dispatch(closeEnvelope).GetClientSessionResponse(); closed == nil || !closed.Accepted {
		t.Fatalf("session close failed: %#v", closed)
	}
	second := terminalIdentityOpen(t, daemon, "term-echo")
	if !second.Accepted || second.CallerIdentity != "client:term-echo" {
		t.Fatalf("reopen lost the stable principal: %#v", second)
	}
	if second.SessionId == first.SessionId {
		t.Fatal("reopen must mint a fresh ephemeral session transport")
	}

	// The new session's reply registration drains the SAME retained agent.
	writer := make(chan *subagentsv1.Envelope, 8)
	closed := make(chan struct{})
	defer close(closed)
	daemon.registerActorReplySession(&subagentsv1.Envelope{SessionId: second.SessionId, GenerationId: second.GenerationId, CallerIdentity: second.CallerIdentity, SessionCredential: second.SessionCredential}, writer, closed)
	select {
	case frame := <-writer:
		reply := frame.GetActorMessageReplyFrame()
		if reply == nil || reply.CompletionKey != "completion-echo" || reply.OriginalRequestId != "request-echo" || string(reply.BoundedResult) != "orphaned answer" {
			t.Fatalf("drained completion mismatch: %#v", reply)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("retained completion was not drained to the reattached session")
	}

	session := application.OpenSession{SessionID: second.SessionId, GenerationID: second.GenerationId, Caller: second.CallerIdentity, Credential: second.SessionCredential}
	matching := 0
	for _, agent := range terminalIdentityList(t, daemon, session) {
		if agent.AgentId == "client:term-echo" {
			matching++
		}
	}
	if matching != 1 {
		t.Fatalf("stable identity minted %d terminal agents, want exactly 1", matching)
	}
}

// TestClientTerminalIdentitySurvivesDaemonRestart proves reconnect after a
// daemon restart reattaches the SAME durable terminal agent: the reconciled
// record materializes the agent, a new OPEN reuses the principal, and no
// duplicate registration appears.
func TestClientTerminalIdentitySurvivesDaemonRestart(t *testing.T) {
	root := t.TempDir()
	_ = os.Chmod(root, 0o700)
	stateDir := filepath.Join(root, "state")
	store, err := durablestate.New(filepath.Join(stateDir, "registrations"))
	if err != nil {
		t.Fatal(err)
	}
	record := quarantineRestartRecord("client:term-restart")
	if err := store.Save(context.Background(), record); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", filepath.Join(root, "control.sock"))
	if err != nil {
		t.Fatal(err)
	}
	config := HostedAdminConfig{Enabled: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge", StateDirectory: stateDir, PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: filepath.Join(root, "admin.json"), DefaultProjectDirectory: root, TrustProject: true}
	daemon, err := startWithListener(context.Background(), listener, config, listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	}()

	reopened := terminalIdentityOpen(t, daemon, "term-restart")
	if !reopened.Accepted || reopened.CallerIdentity != "client:term-restart" {
		t.Fatalf("restart reopen lost the durable principal: %#v", reopened)
	}
	if err := daemon.ensureTerminalAgent(context.Background(), "client:term-restart"); err != nil {
		t.Fatalf("reattach after restart failed: %v", err)
	}
	records, err := daemon.durableStore.LoadAll(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	matching := 0
	for _, candidate := range records {
		if candidate.AgentID == "client:term-restart" {
			matching++
		}
	}
	if matching != 1 {
		t.Fatalf("restart reattach produced %d durable records, want 1", matching)
	}
	session := application.OpenSession{SessionID: reopened.SessionId, GenerationID: reopened.GenerationId, Caller: reopened.CallerIdentity, Credential: reopened.SessionCredential}
	listed := 0
	for _, agent := range terminalIdentityList(t, daemon, session) {
		if agent.AgentId == "client:term-restart" {
			listed++
		}
	}
	if listed != 1 {
		t.Fatalf("restart reattach listed %d terminal agents, want 1", listed)
	}
}

// TestClientTerminalIdentityConcurrentOpensMintOneAgent proves concurrent
// connections from one terminal identity cannot mint duplicate agents.
func TestClientTerminalIdentityConcurrentOpensMintOneAgent(t *testing.T) {
	daemon, stop := terminalIdentityHarness(t)
	defer stop()

	const workers = 4
	responses := make([]*subagentsv1.ClientSessionResponse, workers)
	var wg sync.WaitGroup
	var mu sync.Mutex
	for index := 0; index < workers; index++ {
		wg.Add(1)
		go func(slot int) {
			defer wg.Done()
			response := terminalIdentityOpen(t, daemon, "term-race")
			// Each connection independently triggers the terminal-agent
			// registration path exactly as a first actor message would.
			if err := daemon.ensureTerminalAgent(context.Background(), "client:term-race"); err != nil {
				t.Errorf("concurrent terminal registration failed: %v", err)
			}
			mu.Lock()
			responses[slot] = response
			mu.Unlock()
		}(index)
	}
	wg.Wait()
	for index, response := range responses {
		if response == nil || !response.Accepted || response.CallerIdentity != "client:term-race" {
			t.Fatalf("worker %d lost the stable principal: %#v", index, response)
		}
	}
	session := application.OpenSession{SessionID: responses[0].SessionId, GenerationID: responses[0].GenerationId, Caller: responses[0].CallerIdentity, Credential: responses[0].SessionCredential}
	matching := 0
	for _, agent := range terminalIdentityList(t, daemon, session) {
		if agent.AgentId == "client:term-race" {
			matching++
		}
	}
	if matching != 1 {
		t.Fatalf("concurrent opens minted %d terminal agents, want 1", matching)
	}
}

// TestClientSessionOpenRejectsInvalidTerminalIdentity keeps the stable
// principal fail-closed: malformed identities are rejected instead of being
// silently degraded to an unpredictable principal.
func TestClientSessionOpenRejectsInvalidTerminalIdentity(t *testing.T) {
	daemon, stop := terminalIdentityHarness(t)
	defer stop()
	for _, identity := range []string{"bad/id!", "with space", "unicode-é", "0123456789012345678901234567890123456789012345678", "colon:identity"} {
		envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: time.Now().String(), DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli(), SessionCredential: daemon.adminCredential, Payload: &subagentsv1.Envelope_ClientSessionRequest{ClientSessionRequest: &subagentsv1.ClientSessionRequest{Operation: subagentsv1.ClientSessionRequest_OPERATION_OPEN, TerminalIdentity: identity}}}
		response := daemon.dispatch(envelope)
		if failure := response.GetProtocolError(); failure == nil || failure.Code != subagentsv1.ProtocolError_CODE_INVALID_REQUEST {
			t.Fatalf("identity %q must fail closed with INVALID_REQUEST, got %#v", identity, response)
		}
	}
}

// TestClientSessionOpenWithoutTerminalIdentityKeepsEphemeralMint guards the
// legacy contract: older clients that send no terminal identity still mint an
// ephemeral principal instead of failing.
func TestClientSessionOpenWithoutTerminalIdentityKeepsEphemeralMint(t *testing.T) {
	daemon, stop := terminalIdentityHarness(t)
	defer stop()
	envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: time.Now().String(), DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli(), SessionCredential: daemon.adminCredential, Payload: &subagentsv1.Envelope_ClientSessionRequest{ClientSessionRequest: &subagentsv1.ClientSessionRequest{Operation: subagentsv1.ClientSessionRequest_OPERATION_OPEN}}}
	response := daemon.dispatch(envelope).GetClientSessionResponse()
	if response == nil || !response.Accepted || response.CallerIdentity == "" || len(response.SessionCredential) != 32 {
		t.Fatalf("legacy ephemeral open regressed: %#v", response)
	}
	if response.CallerIdentity == "client:" {
		t.Fatalf("legacy ephemeral principal must not be empty: %#v", response)
	}
}
