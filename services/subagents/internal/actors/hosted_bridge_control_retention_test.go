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

func TestAcknowledgedTypedControlChainsRetireWithinBoundedMutationCache(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("control-retention")
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
	registration := &application.RegisterAgent{AgentID: "target", HostedPiRuntime: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeReady, RuntimeID: "runtime", Incarnation: 1, BridgeReady: true}, AllowedCapability: []string{"hosted_bridge", "control_abort"}, Retention: "explicit", Recovery: "owned"}
	pid, err := system.Spawn(ctx, "control-retention-agent", actors.NewAgentActor(registration))
	if err != nil {
		t.Fatal(err)
	}
	runtime, _ := system.Spawn(ctx, "control-retention-runtime", &inertRuntimeActor{})
	_ = system.NoSender().Tell(ctx, pid, &application.BindHostedPiRuntimeActor{PID: runtime})
	ask := func(message any) any {
		value, err := system.NoSender().Ask(ctx, pid, message, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	attached := ask(&application.AttachAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", RequestedCapabilities: registration.AllowedCapability, IssuedHandle: "handle"}).(*application.AttachResult)
	ask(&application.BridgeConnect{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", AgentID: "target", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime", Incarnation: 1, PiSessionID: "pi"})
	ask(&application.BridgeLifecycle{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", AgentID: "target", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime", Incarnation: 1, Event: application.BridgeLifecycleReady})
	control := func(sequence uint64, id string) *application.BridgeControl {
		return &application.BridgeControl{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, SourceMutationSequence: sequence, SourceAgentID: "source", TargetAgentID: "target", RequestID: id, DedupeID: id, ChainID: "chain-" + id, Deadline: time.Now().Add(time.Minute), HopLimit: 2, Intent: application.BridgeControlAbort}
	}
	sequence := uint64(1)
	first := control(sequence, "first")
	if !ask(first).(*application.BridgeIntentResult).Accepted {
		t.Fatal("first control rejected")
	}
	sequence++
	inUse := control(sequence, "in-use")
	inUse.ChainID = first.ChainID
	if value := ask(inUse).(*application.BridgeIntentResult); value.Accepted || value.Reason == "" {
		t.Fatalf("active chain accepted: %#v", value)
	}
	ackAll := func() {
		poll := ask(&application.PollBridge{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, MaxItems: 64}).(*application.BridgePollResult)
		for _, delivery := range poll.Deliveries {
			if !ask(identityAck("session", "generation", "hosted:source", attached.Handle, attached.Fence, "runtime", "pi", delivery, true, nil)).(*application.BridgeDeliveryAckResult).Accepted {
				t.Fatal("control ACK rejected")
			}
		}
	}
	ackAll()
	sequence-- // rejected chain-in-use did not consume source high-water
	var recent *application.BridgeControl
	for index := 0; index < 1100; index++ {
		sequence++
		recent = control(sequence, fmt.Sprintf("control-%d", index))
		if !ask(recent).(*application.BridgeIntentResult).Accepted {
			t.Fatalf("control admission exhausted at %d", index)
		}
		ackAll()
	}
	if replay := ask(recent).(*application.BridgeIntentResult); !replay.Accepted || !replay.Completed {
		t.Fatalf("recent control result not retained: %#v", replay)
	}
	if old := ask(first).(*application.BridgeIntentResult); old.Accepted || old.Reason == "" {
		t.Fatalf("old control replay executed: %#v", old)
	}
	sequence++
	next := control(sequence, "after-window")
	next.ChainID = first.ChainID
	if !ask(next).(*application.BridgeIntentResult).Accepted {
		t.Fatal("completed control chain did not retire or cache exhausted")
	}
}
