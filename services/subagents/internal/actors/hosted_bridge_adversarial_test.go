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

type inertRuntimeActor struct{}

func (*inertRuntimeActor) PreStart(*goakt.Context) error     { return nil }
func (*inertRuntimeActor) PostStop(*goakt.Context) error     { return nil }
func (*inertRuntimeActor) Receive(ctx *goakt.ReceiveContext) { ctx.Unhandled() }

func TestHostedBridgePaginationAcknowledgementBackpressureAndSubscriptionSemantics(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("hosted-bridge-adversarial", goakt.WithPubSub(), goakt.WithMessageRetention(time.Minute))
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
	registration := &application.RegisterAgent{AgentID: "target", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: "runtime"}, HostedPiRuntime: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeReady, RuntimeID: "runtime", Incarnation: 1, BridgeReady: true}, AllowedCapability: []string{"observe", "hosted_bridge", "send", "ask", "control_abort", "control_shutdown"}, Retention: "explicit", Recovery: "owned"}
	pid, err := system.Spawn(ctx, "adversarial-hosted-agent", actors.NewAgentActor(registration))
	if err != nil {
		t.Fatal(err)
	}
	runtimePID, err := system.Spawn(ctx, "adversarial-inert-runtime", &inertRuntimeActor{})
	if err != nil {
		t.Fatal(err)
	}
	if err := system.NoSender().Tell(ctx, pid, &application.BindHostedPiRuntimeActor{PID: runtimePID}); err != nil {
		t.Fatal(err)
	}
	ask := func(message any) any {
		value, err := system.NoSender().Ask(ctx, pid, message, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	attached := ask(&application.AttachAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", RequestedCapabilities: registration.AllowedCapability, IssuedHandle: "handle"}).(*application.AttachResult)
	if !ask(&application.BridgeConnect{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", AgentID: "target", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime", Incarnation: 1, PiSessionID: "pi-session"}).(*application.BridgeResult).Accepted {
		t.Fatal("bridge connect failed")
	}
	intent := func(index int) *application.BridgeIntent {
		return &application.BridgeIntent{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, SourceMutationSequence: uint64(index + 1), SourceAgentID: "source", TargetAgentID: "target", RequestID: fmt.Sprintf("request-%d", index), RequiredCapability: "send", DedupeID: fmt.Sprintf("dedupe-%d", index), ChainID: fmt.Sprintf("chain-%d", index), Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: []byte(`{"kind":"shutdown"}`)}
	}
	for index := 0; index < 65; index++ {
		if !ask(intent(index)).(*application.BridgeIntentResult).Accepted {
			t.Fatalf("delivery %d rejected", index)
		}
	}
	poll := func(after uint64, max uint32) *application.BridgePollResult {
		return ask(&application.PollBridge{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, AfterSequence: after, MaxItems: max}).(*application.BridgePollResult)
	}
	repeatedChain := intent(65)
	repeatedChain.ChainID = "chain-0"
	if ask(repeatedChain).(*application.BridgeIntentResult).Accepted {
		t.Fatal("repeated provenance chain was accepted")
	}
	first := poll(0, 64)
	if len(first.Deliveries) != 64 || first.Deliveries[0].Kind != application.BridgeDeliveryNotification || !first.More || first.LatestSequence != first.Deliveries[63].Sequence {
		t.Fatalf("first page lost cursor or typed semantics: %#v", first)
	}
	second := poll(first.LatestSequence, 64)
	if len(second.Deliveries) != 1 || second.More || second.LatestSequence != second.Deliveries[0].Sequence {
		t.Fatalf("second page lost backlog: %#v", second)
	}
	all := append(first.Deliveries, second.Deliveries...)
	for _, delivery := range all {
		if !ask(&application.BridgeDeliveryAck{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, Sequence: delivery.Sequence, DedupeID: delivery.DedupeID, Delivered: true}).(*application.BridgeDeliveryAckResult).Accepted {
			t.Fatal("ack rejected")
		}
	}
	if ask(&application.BridgeDeliveryAck{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, Sequence: all[0].Sequence, DedupeID: all[0].DedupeID, Delivered: true}).(*application.BridgeDeliveryAckResult).Accepted {
		t.Fatal("duplicate acknowledgement was accepted")
	}
	for index := 65; index < 321; index++ {
		if !ask(intent(index)).(*application.BridgeIntentResult).Accepted {
			t.Fatalf("retained delivery %d rejected", index)
		}
	}
	if ask(intent(321)).(*application.BridgeIntentResult).Accepted {
		t.Fatal("overload silently evicted an unacknowledged delivery")
	}

	rejectedReplay := make(chan application.OperationResult, 1)
	if err := system.NoSender().Tell(ctx, pid, &application.SubscribeAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, AfterRevision: 1, Result: rejectedReplay}); err != nil {
		t.Fatal(err)
	}
	if result := <-rejectedReplay; result.Completed || result.Reason == "" {
		t.Fatal("unsupported nonzero after_revision was accepted")
	}
	ask(&application.BridgeLifecycle{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", AgentID: "target", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime", Incarnation: 1, Event: application.BridgeLifecycleAgentStart})
	if events := poll(321, 64).Events; len(events) != 0 {
		t.Fatal("poll exposed events without an acknowledged subscription")
	}
	subscribed := make(chan application.OperationResult, 1)
	if err := system.NoSender().Tell(ctx, pid, &application.SubscribeAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, Result: subscribed}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-subscribed:
		if !result.Completed {
			t.Fatalf("subscribe failed: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("subscribe acknowledgement timed out")
	}
	ask(&application.BridgeLifecycle{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", AgentID: "target", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime", Incarnation: 1, Event: application.BridgeLifecycleAgentSettled})
	withSubscription := poll(321, 64)
	if len(withSubscription.Events) == 0 {
		t.Fatal("acknowledged subscription did not grant event polling")
	}
	unsubscribed := make(chan application.OperationResult, 1)
	if err := system.NoSender().Tell(ctx, pid, &application.UnsubscribeAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, Result: unsubscribed}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-unsubscribed:
		if !result.Completed {
			t.Fatalf("unsubscribe failed: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("unsubscribe acknowledgement timed out")
	}
	if events := poll(withSubscription.LatestSequence, 64).Events; len(events) != 0 {
		t.Fatal("unsubscribe did not revoke event polling")
	}
}
