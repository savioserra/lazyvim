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

func TestAcknowledgedBridgeIdentityRetentionStaysBoundedAndReplayable(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("hosted-retention")
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
	registration := &application.RegisterAgent{AgentID: "target", HostedPiRuntime: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeReady, RuntimeID: "runtime", Incarnation: 1, BridgeReady: true}, AllowedCapability: []string{"hosted_bridge", "send", "control_abort", "control_shutdown"}, Retention: "explicit", Recovery: "owned"}
	pid, err := system.Spawn(ctx, "retention-agent", actors.NewAgentActor(registration))
	if err != nil {
		t.Fatal(err)
	}
	runtime, _ := system.Spawn(ctx, "retention-runtime", &inertRuntimeActor{})
	_ = system.NoSender().Tell(ctx, pid, &application.BindHostedPiRuntimeActor{PID: runtime})
	ask := func(message any) any {
		value, err := system.NoSender().Ask(ctx, pid, message, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	attached := ask(&application.AttachAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", RequestedCapabilities: []string{"hosted_bridge", "send", "control_abort", "control_shutdown"}, IssuedHandle: "handle"}).(*application.AttachResult)
	ask(&application.BridgeConnect{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", AgentID: "target", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime", Incarnation: 1, PiSessionID: "pi"})
	ask(&application.BridgeLifecycle{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", AgentID: "target", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime", Incarnation: 1, Event: application.BridgeLifecycleReady})
	intent := func(index int) *application.BridgeIntent {
		return &application.BridgeIntent{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, SourceMutationSequence: uint64(index + 1), SourceAgentID: "source", TargetAgentID: "target", RequestID: fmt.Sprintf("request-%d", index), RequiredCapability: "send", DedupeID: fmt.Sprintf("dedupe-%d", index), ChainID: fmt.Sprintf("chain-%d", index), Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: []byte("notification")}
	}
	cursor := uint64(0)
	for index := 0; index < 1100; index++ {
		if !ask(intent(index)).(*application.BridgeIntentResult).Accepted {
			t.Fatalf("acknowledged sequence exhausted admission at %d", index)
		}
		poll := ask(&application.PollBridge{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, AfterSequence: cursor, MaxItems: 1}).(*application.BridgePollResult)
		if len(poll.Deliveries) != 1 {
			t.Fatalf("delivery %d missing", index)
		}
		delivery := poll.Deliveries[0]
		cursor = poll.LatestSequence
		if !ask(&application.BridgeDeliveryAck{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, Sequence: delivery.Sequence, DedupeID: delivery.DedupeID, Delivered: true}).(*application.BridgeDeliveryAckResult).Accepted {
			t.Fatalf("ack %d rejected", index)
		}
	}
	reconnected := ask(&application.BridgeConnect{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", AgentID: "target", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime", Incarnation: 1, PiSessionID: "pi"}).(*application.BridgeResult)
	if !reconnected.Accepted || reconnected.Fence != attached.Fence {
		t.Fatalf("same-session reconnect rotated sequence scope: %#v", reconnected)
	}
	recent := ask(intent(1099)).(*application.BridgeIntentResult)
	if !recent.Accepted || !recent.Completed {
		t.Fatalf("recent completed replay was not retained: %#v", recent)
	}
	if old := ask(intent(0)).(*application.BridgeIntentResult); old.Accepted || old.Reason == "" {
		t.Fatalf("retired mutation sequence replayed instead of failing closed: %#v", old)
	}
	collision := intent(1099)
	collision.Payload = []byte("changed")
	if value := ask(collision).(*application.BridgeIntentResult); value.Accepted || value.Reason == "" {
		t.Fatalf("recent sequence collision accepted: %#v", value)
	}
	if !ask(intent(1100)).(*application.BridgeIntentResult).Accepted {
		t.Fatal("new admission failed after more than 1024 acknowledged deliveries")
	}
	control := &application.BridgeControl{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, SourceMutationSequence: 1102, SourceAgentID: "source", TargetAgentID: "target", RequestID: "control", DedupeID: "control", ChainID: "control-chain", Deadline: time.Now().Add(time.Minute), HopLimit: 2, Intent: application.BridgeControlAbort}
	if !ask(control).(*application.BridgeIntentResult).Accepted {
		t.Fatal("sequenced control rejected")
	}
	repeatedControlChain := *control
	repeatedControlChain.SourceMutationSequence = 1103
	repeatedControlChain.DedupeID = "control-in-use"
	repeatedControlChain.RequestID = "control-in-use"
	if value := ask(&repeatedControlChain).(*application.BridgeIntentResult); value.Accepted || value.Reason == "" {
		t.Fatalf("active control chain identity was accepted: %#v", value)
	}
	controlPoll := ask(&application.PollBridge{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, AfterSequence: cursor, MaxItems: 64}).(*application.BridgePollResult)
	for _, delivery := range controlPoll.Deliveries {
		_ = ask(&application.BridgeDeliveryAck{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, Sequence: delivery.Sequence, DedupeID: delivery.DedupeID, Delivered: true})
	}
	if replay := ask(control).(*application.BridgeIntentResult); !replay.Accepted || !replay.Completed {
		t.Fatalf("recent control retry did not return exact result: %#v", replay)
	}
	retiredControlChain := *control
	retiredControlChain.SourceMutationSequence = 1103
	retiredControlChain.DedupeID = "control-after-ack"
	retiredControlChain.RequestID = "control-after-ack"
	if value := ask(&retiredControlChain).(*application.BridgeIntentResult); !value.Accepted {
		t.Fatalf("completed control chain did not retire: %#v", value)
	}
	collisionControl := *control
	collisionControl.Intent = application.BridgeControlShutdown
	if value := ask(&collisionControl).(*application.BridgeIntentResult); value.Accepted || value.Reason == "" {
		t.Fatalf("control sequence collision accepted: %#v", value)
	}
	replaced := ask(&application.BridgeReplace{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", AgentID: "target", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime", Incarnation: 1, PreviousPiSessionID: "pi", NewPiSessionID: "pi-two", NewHandle: "replacement-handle"}).(*application.BridgeResult)
	if !replaced.Accepted || replaced.Fence == attached.Fence {
		t.Fatalf("explicit replacement failed: %#v", replaced)
	}
	ask(&application.BridgeLifecycle{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", AgentID: "target", Handle: replaced.Handle, Fence: replaced.Fence, RuntimeID: "runtime", Incarnation: 1, Event: application.BridgeLifecycleReady})
	fresh := intent(0)
	fresh.Handle, fresh.Fence = freshHandle(replaced)
	if !ask(fresh).(*application.BridgeIntentResult).Accepted {
		t.Fatal("explicit replacement did not rotate mutation sequence scope")
	}
	gap := intent(2)
	gap.Handle, gap.Fence = freshHandle(replaced)
	if value := ask(gap).(*application.BridgeIntentResult); value.Accepted || value.Reason == "" {
		t.Fatalf("mutation sequence gap accepted: %#v", value)
	}
	next := intent(1)
	next.Handle, next.Fence = freshHandle(replaced)
	if !ask(next).(*application.BridgeIntentResult).Accepted {
		t.Fatal("gap rejection incorrectly advanced high-water")
	}
	stale := intent(1099)
	if value := ask(stale).(*application.BridgeIntentResult); value.Accepted || value.Reason == "" {
		t.Fatalf("revoked fence disclosed retained result: %#v", value)
	}
}

func freshHandle(result *application.BridgeResult) (string, uint64) {
	return result.Handle, result.Fence
}
