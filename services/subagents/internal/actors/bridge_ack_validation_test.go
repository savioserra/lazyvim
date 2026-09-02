package actors_test

import (
	"context"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
)

func TestBridgeDeliveryAckValidationRetainsPromptDelivery(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("bridge-ack-validation")
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
	registration := &application.RegisterAgent{AgentID: "target", HostedPiRuntime: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeReady, RuntimeID: "runtime", Incarnation: 1, BridgeReady: true}, AllowedCapability: []string{"hosted_bridge", "prompt"}}
	pid, err := system.Spawn(ctx, "ack-agent", actors.NewBridgeDeliveryFixtureAgent(registration))
	if err != nil {
		t.Fatal(err)
	}
	runtime, _ := system.Spawn(ctx, "ack-runtime", &inertRuntimeActor{})
	_ = system.NoSender().Tell(ctx, pid, &application.BindHostedPiRuntimeActor{PID: runtime})
	ask := func(message any) any {
		value, err := system.NoSender().Ask(ctx, pid, message, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	attached := ask(&application.AttachAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", RequestedCapabilities: []string{"hosted_bridge", "prompt"}, IssuedHandle: "handle"}).(*application.AttachResult)
	connected := ask(&application.BridgeConnect{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", AgentID: "target", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime", Incarnation: 1, PiSessionID: "pi"}).(*application.BridgeResult)
	if !connected.Accepted {
		t.Fatalf("connect rejected: %#v", connected)
	}
	ask(&application.BridgeLifecycle{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", AgentID: "target", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime", Incarnation: 1, Event: application.BridgeLifecycleReady})
	intent := &application.BridgeIntent{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, SourceMutationSequence: 1, SourceAgentID: "source", TargetAgentID: "target", RequestID: "prompt", RequiredCapability: "prompt", DedupeID: "dedupe", ChainID: "chain", Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessagePrompt, Payload: []byte("do work")}
	if !ask(intent).(*application.BridgeIntentResult).Accepted {
		t.Fatal("prompt not accepted")
	}
	poll := ask(&application.PollBridge{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, AfterSequence: 0, MaxItems: 64}).(*application.BridgePollResult)
	if len(poll.Deliveries) != 1 {
		t.Fatalf("delivery missing: %#v", poll)
	}
	delivery := poll.Deliveries[0]
	oversized := make([]byte, 16*1024+1)
	if result := ask(identityAck("session", "generation", "hosted:source", attached.Handle, attached.Fence, "runtime", "pi", delivery, true, oversized)).(*application.BridgeDeliveryAckResult); result.Accepted || result.Reason == "" {
		t.Fatalf("oversized ack accepted: %#v", result)
	}
	replay := ask(&application.PollBridge{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, AfterSequence: 0, MaxItems: 64}).(*application.BridgePollResult)
	if len(replay.Deliveries) != 1 || replay.Deliveries[0].Sequence != delivery.Sequence {
		t.Fatalf("rejected oversized ack removed delivery: %#v", replay)
	}
	// Empty settled output is valid lifecycle evidence. It commits once and the
	// thread introspector, rather than ACK validation, decides that the model
	// still owes a deliverable and schedules resumption.
	if result := ask(identityAck("session", "generation", "hosted:source", attached.Handle, attached.Fence, "runtime", "pi", delivery, true, nil)).(*application.BridgeDeliveryAckResult); !result.Accepted {
		t.Fatalf("empty settled prompt ack rejected: %#v", result)
	}
	committed := ask(&application.PollBridge{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, AfterSequence: 0, MaxItems: 64}).(*application.BridgePollResult)
	if len(committed.Deliveries) != 0 {
		t.Fatalf("committed empty settlement replayed original delivery: %#v", committed)
	}
}

func TestNilBridgeDeliveryAckDoesNotPanic(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("bridge-nil-ack")
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
	pid, err := system.Spawn(ctx, "nil-ack-agent", actors.NewBridgeDeliveryFixtureAgent(&application.RegisterAgent{AgentID: "target"}))
	if err != nil {
		t.Fatal(err)
	}
	var nilAck *application.BridgeDeliveryAck
	if err := system.NoSender().Tell(ctx, pid, nilAck); err != nil {
		t.Fatal(err)
	}
}
