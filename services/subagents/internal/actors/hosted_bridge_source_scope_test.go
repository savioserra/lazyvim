package actors_test

import (
	"context"
	"encoding/hex"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
)

func TestBridgeConnectReturnsActorMessageHighWaterFromDurableSourceHistory(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("bridge-message-high-water")
	if err != nil {
		t.Fatal(err)
	}
	if err := system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		stop, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = system.Stop(stop)
	})
	binding := application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeReady, RuntimeID: "runtime", Incarnation: 2, BridgeReady: true}
	state := application.DurableAgentState{
		SourceOutbox: []application.DurableActorTaskOutboxItem{{TaskID: "source:pending:chain:4", SourceMutationSequence: 4}},
		SourceTaskHistory: []application.ActorTaskCompleted{
			{OriginalRequestID: "request-done", DedupeID: "done", ChainID: "chain", SourceMutationSequence: 7, Source: application.CommunicationPeer{StableID: "source"}},
			{OriginalRequestID: "incoming-done", DedupeID: "incoming", ChainID: "incoming-chain", SourceMutationSequence: 99, Source: application.CommunicationPeer{StableID: "another-source"}},
		},
	}
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "source", Binding: binding, AgentState: state}
	registration := &application.RegisterAgent{AgentID: "source", HostedPiRuntime: binding, AllowedCapability: []string{"hosted_bridge", "observe", "send"}, Retention: "explicit", Recovery: "owned", DurableRecord: &record}
	pid, err := system.Spawn(ctx, "high-water-agent", actors.NewAgentActor(registration))
	if err != nil {
		t.Fatal(err)
	}
	taskResult := make(chan application.BridgeIntentResult, 1)
	if err := system.NoSender().Tell(ctx, pid, &application.SendActorTask{TargetPID: pid, TargetPeer: application.CommunicationPeer{StableID: "source"}, RequestID: "request-low", DedupeID: "low", ChainID: "chain-low", RequiredCapability: "send", SourceMutationSequence: 4, Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: []byte("low"), Receipt: taskResult}); err != nil {
		t.Fatal(err)
	}
	if result := <-taskResult; result.Accepted || !strings.Contains(result.Reason, "collision") {
		t.Fatalf("daemon did not retain prior source mutation sequence: %#v", result)
	}
	taskResult = make(chan application.BridgeIntentResult, 1)
	if err := system.NoSender().Tell(ctx, pid, &application.SendActorTask{TargetPID: pid, TargetPeer: application.CommunicationPeer{StableID: "source"}, RequestID: "request-next", DedupeID: "next", ChainID: "chain-next", RequiredCapability: "send", SourceMutationSequence: 8, Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: []byte("next"), Receipt: taskResult}); err != nil {
		t.Fatal(err)
	}
	if result := <-taskResult; !result.Accepted {
		t.Fatalf("daemon rejected adopted next source mutation sequence: %#v", result)
	}
	attached := make(chan application.AttachResult, 1)
	if err := system.NoSender().Tell(ctx, pid, &application.AttachAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", RequestedCapabilities: registration.AllowedCapability, IssuedHandle: "handle", Result: attached}); err != nil {
		t.Fatal(err)
	}
	attachment := <-attached
	if !attachment.Completed {
		t.Fatalf("attach failed: %#v", attachment)
	}
	connected := make(chan application.BridgeResult, 1)
	if err := system.NoSender().Tell(ctx, pid, &application.BridgeConnect{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", AgentID: "source", Handle: attachment.Handle, Fence: attachment.Fence, RuntimeID: "runtime", Incarnation: 2, PiSessionID: "pi", Result: connected}); err != nil {
		t.Fatal(err)
	}
	connect := <-connected
	if !connect.Accepted || connect.ActorMessageHighWater != 8 {
		t.Fatalf("bridge connect did not return authoritative actor-message high-water: %#v", connect)
	}
}

func TestHostedMutationScopesAreExactPerAuthenticatedSource(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("hosted-source-scopes")
	if err != nil {
		t.Fatal(err)
	}
	if err := system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		stop, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = system.Stop(stop)
	})
	registration := &application.RegisterAgent{AgentID: "target", HostedPiRuntime: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeReady, RuntimeID: "runtime", Incarnation: 1, BridgeReady: true}, AllowedCapability: []string{"hosted_bridge", "send", "ask", "control_abort"}, Retention: "explicit", Recovery: "owned"}
	pid, err := system.Spawn(ctx, "source-scope-agent", actors.NewAgentActor(registration))
	if err != nil {
		t.Fatal(err)
	}
	runtime, _ := system.Spawn(ctx, "source-scope-runtime", &inertRuntimeActor{})
	_ = system.NoSender().Tell(ctx, pid, &application.BindHostedPiRuntimeActor{PID: runtime})
	ask := func(message any) any {
		value, err := system.NoSender().Ask(ctx, pid, message, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	attach := func(session, generation, principal, handle string) *application.AttachResult {
		return ask(&application.AttachAgent{SessionID: session, GenerationID: generation, Principal: principal, RequestedCapabilities: registration.AllowedCapability, IssuedHandle: handle}).(*application.AttachResult)
	}
	a := attach("a-session", "a-generation", "hosted:a", "a-handle")
	b := attach("b-session", "b-generation", "hosted:b", "b-handle")
	if !ask(&application.BridgeConnect{SessionID: "a-session", GenerationID: "a-generation", Principal: "hosted:a", AgentID: "target", Handle: a.Handle, Fence: a.Fence, RuntimeID: "runtime", Incarnation: 1, PiSessionID: "pi-a"}).(*application.BridgeResult).Accepted {
		t.Fatal("bridge connect failed")
	}
	ask(&application.BridgeLifecycle{SessionID: "a-session", GenerationID: "a-generation", Principal: "hosted:a", AgentID: "target", Handle: a.Handle, Fence: a.Fence, RuntimeID: "runtime", Incarnation: 1, Event: application.BridgeLifecycleReady})
	intent := func(source string, attachment *application.AttachResult, sequence uint64, mode application.BridgeMessageMode) *application.BridgeIntent {
		session, generation, principal := "a-session", "a-generation", "hosted:a"
		if source == "b" {
			session, generation, principal = "b-session", "b-generation", "hosted:b"
		}
		return &application.BridgeIntent{SessionID: session, GenerationID: generation, Principal: principal, Handle: attachment.Handle, Fence: attachment.Fence, SourceMutationSequence: sequence, SourceAgentID: source, TargetAgentID: "target", RequestID: fmt.Sprintf("%s-%d", source, sequence), RequiredCapability: map[application.BridgeMessageMode]string{application.BridgeMessageTell: "send", application.BridgeMessageAsk: "ask"}[mode], DedupeID: fmt.Sprintf("same-%d", sequence), ChainID: fmt.Sprintf("same-chain-%d", sequence), Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: mode, Payload: []byte(source)}
	}
	if !ask(intent("a", a, 1, application.BridgeMessageTell)).(*application.BridgeIntentResult).Accepted || !ask(intent("b", b, 1, application.BridgeMessageTell)).(*application.BridgeIntentResult).Accepted {
		t.Fatal("colliding source sequence/dedupe/chain did not coexist")
	}
	if !ask(intent("a", a, 2, application.BridgeMessageTell)).(*application.BridgeIntentResult).Accepted || !ask(intent("b", b, 2, application.BridgeMessageTell)).(*application.BridgeIntentResult).Accepted {
		t.Fatal("alternating source sequence reset another source")
	}
	reconnect := ask(&application.BridgeConnect{SessionID: "a-session", GenerationID: "a-generation", Principal: "hosted:a", AgentID: "target", Handle: a.Handle, Fence: a.Fence, RuntimeID: "runtime", Incarnation: 1, PiSessionID: "pi-a"}).(*application.BridgeResult)
	if !reconnect.Accepted || reconnect.Fence != a.Fence {
		t.Fatal("same-source reconnect rotated fence")
	}
	if result := ask(intent("a", a, 1, application.BridgeMessageTell)).(*application.BridgeIntentResult); !result.Accepted {
		t.Fatalf("retained exact retry returned false result: %#v", result)
	}
	replaced := ask(&application.BridgeReplace{SessionID: "a-session", GenerationID: "a-generation", Principal: "hosted:a", AgentID: "target", Handle: a.Handle, Fence: a.Fence, RuntimeID: "runtime", Incarnation: 1, PreviousPiSessionID: "pi-a", NewPiSessionID: "pi-a-two", NewHandle: "a-replaced"}).(*application.BridgeResult)
	if !replaced.Accepted {
		t.Fatal("source A replacement failed")
	}
	ask(&application.BridgeLifecycle{SessionID: "a-session", GenerationID: "a-generation", Principal: "hosted:a", AgentID: "target", Handle: replaced.Handle, Fence: replaced.Fence, RuntimeID: "runtime", Incarnation: 1, Event: application.BridgeLifecycleReady})
	if !ask(intent("b", b, 3, application.BridgeMessageTell)).(*application.BridgeIntentResult).Accepted {
		t.Fatal("source A replacement altered source B high-water")
	}
	freshA := intent("a", replacedAttach(replaced), 1, application.BridgeMessageTell)
	if !ask(freshA).(*application.BridgeIntentResult).Accepted {
		t.Fatal("replacement did not create fresh source A scope")
	}
	drop := make(chan application.OperationResult, 1)
	_ = system.NoSender().Tell(ctx, pid, &application.DropSession{SessionID: "b-session", GenerationID: "b-generation", Result: drop})
	if result := <-drop; !result.Completed {
		t.Fatal("source B revoke failed")
	}
	if result := ask(intent("b", b, 3, application.BridgeMessageTell)).(*application.BridgeIntentResult); result.Accepted || result.Reason == "" {
		t.Fatal("revoked source obtained replay")
	}
	poll := ask(&application.PollBridge{SessionID: "a-session", GenerationID: "a-generation", Principal: "hosted:a", Handle: replaced.Handle, Fence: replaced.Fence, MaxItems: 64}).(*application.BridgePollResult)
	if len(poll.Deliveries) != 6 {
		t.Fatalf("another source reset/lost pending deliveries: %d", len(poll.Deliveries))
	}
	for _, delivery := range poll.Deliveries {
		ack := ask(identityAck("a-session", "a-generation", "hosted:a", replaced.Handle, replaced.Fence, "runtime", "pi-a-two", delivery, true, nil)).(*application.BridgeDeliveryAckResult)
		if !ack.Accepted {
			t.Fatal("retained delivery ACK rejected")
		}
	}
}

func replacedAttach(result *application.BridgeResult) *application.AttachResult {
	return &application.AttachResult{Completed: true, Handle: result.Handle, Fence: result.Fence}
}

// TestSourceScopeTokenIsOpaqueBoundedAndUnforgeable proves the serialized
// SourceScope is a server-issued opaque token: bounded length, no raw identity
// tuple material (session, generation, principal, fence, incarnation), stable
// per source scope, and required verbatim by acknowledgement validation.
func TestSourceScopeTokenIsOpaqueBoundedAndUnforgeable(t *testing.T) {
	b := newBridgeHarness(t, "source-scope-token", "target", "alpha")
	if r := b.ask(b.intent(application.BridgeMessageTell, "alpha", "token-1", "chain-token-1", 1)).(*application.BridgeIntentResult); !r.Accepted {
		t.Fatalf("first tell rejected: %#v", r)
	}
	if r := b.ask(b.intent(application.BridgeMessageTell, "alpha", "token-2", "chain-token-2", 2)).(*application.BridgeIntentResult); !r.Accepted {
		t.Fatalf("second tell rejected: %#v", r)
	}
	deliveries := b.poll().Deliveries
	if len(deliveries) != 2 {
		t.Fatalf("expected two deliveries: %#v", deliveries)
	}
	for _, delivery := range deliveries {
		token := delivery.SourceScope
		if token == "" {
			t.Fatal("delivery carried an empty source scope token")
		}
		if len(token) != 2*16 || len(token) > 64 {
			t.Fatalf("source scope token is unbounded: %q", token)
		}
		if _, err := hex.DecodeString(token); err != nil {
			t.Fatalf("source scope token is not opaque server-issued bytes: %q", token)
		}
		// No raw identity-tuple component (session, generation, principal,
		// agent, runtime) or tuple separator may appear inside the token; the
		// fixed-length random hex encoding cannot embed the tuple either.
		for _, leaked := range []string{b.session, b.generation, b.principal, "alpha", "target", "runtime-target", ":"} {
			if leaked != "" && strings.Contains(token, leaked) {
				t.Fatalf("source scope token leaks raw identity material %q: %q", leaked, token)
			}
		}
	}
	if deliveries[0].SourceScope != deliveries[1].SourceScope {
		t.Fatal("same-source deliveries rotated their scope token")
	}
	// Acknowledgement validation requires the exact server-issued token: a
	// mutated token is rejected fail-closed even with every other identity
	// field correct.
	forged := identityAck(b.session, b.generation, b.principal, b.handle, b.fence, "runtime-target", "pi-target", deliveries[0], true, nil)
	forged.SourceScope = deliveries[0].SourceScope + "00"
	if result := b.ask(forged).(*application.BridgeDeliveryAckResult); result.Accepted {
		t.Fatalf("forged source scope token was accepted: %#v", result)
	}
	if result := b.ask(identityAck(b.session, b.generation, b.principal, b.handle, b.fence, "runtime-target", "pi-target", deliveries[0], true, nil)).(*application.BridgeDeliveryAckResult); !result.Accepted {
		t.Fatalf("verbatim source scope token was rejected: %#v", result)
	}
}
