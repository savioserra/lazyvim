package actors_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
)

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
		ack := ask(&application.BridgeDeliveryAck{SessionID: "a-session", GenerationID: "a-generation", Principal: "hosted:a", Handle: replaced.Handle, Fence: replaced.Fence, Sequence: delivery.Sequence, DedupeID: delivery.DedupeID, Delivered: true}).(*application.BridgeDeliveryAckResult)
		if !ack.Accepted {
			t.Fatal("retained delivery ACK rejected")
		}
	}
}

func replacedAttach(result *application.BridgeResult) *application.AttachResult {
	return &application.AttachResult{Completed: true, Handle: result.Handle, Fence: result.Fence}
}
