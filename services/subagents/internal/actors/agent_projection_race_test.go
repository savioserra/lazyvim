package actors

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
	goakterrors "github.com/tochemey/goakt/v4/errors"
)

type rejectFirstCloseMailbox struct {
	actor.Mailbox
	rejected *atomic.Int32
}

type rejectFirstPubSubAcksMailbox struct {
	actor.Mailbox
	rejected *atomic.Uint32
}

func (m *rejectFirstCloseMailbox) Enqueue(message *actor.ReceiveContext) error {
	if _, ok := message.Message().(*closeProjection); ok && m.rejected.CompareAndSwap(0, 1) {
		return goakterrors.ErrMailboxFull
	}
	return m.Mailbox.Enqueue(message)
}

func (m *rejectFirstPubSubAcksMailbox) Enqueue(message *actor.ReceiveContext) error {
	var bit uint32
	switch message.Message().(type) {
	case *actor.SubscribeAck:
		bit = 1
	case *actor.UnsubscribeAck:
		bit = 2
	}
	for bit != 0 {
		current := m.rejected.Load()
		if current&bit != 0 {
			break
		}
		if m.rejected.CompareAndSwap(current, current|bit) {
			return goakterrors.ErrMailboxFull
		}
	}
	return m.Mailbox.Enqueue(message)
}

func TestProjectionCloseBeforeSubscribeAckWaitsForPubSubTeardown(t *testing.T) {
	system, agent := projectionTestSystem(t, func(value *AgentActor) {
		value.projectionSubscriptionDelay = 75 * time.Millisecond
	})
	attached := projectionTestAttach(t, system, agent, "early")
	subscription := make(chan application.OperationResult, 1)
	if err := system.NoSender().Tell(context.Background(), agent, &application.SubscribeAgent{SessionID: "early", GenerationID: "generation", Principal: "caller", Handle: attached.Handle, Fence: attached.Fence, Result: subscription}); err != nil {
		t.Fatal(err)
	}
	waitForActor(t, system, projectionName("early", "generation"))

	dropped := make(chan application.OperationResult, 1)
	if err := system.NoSender().Tell(context.Background(), agent, &application.DropSession{SessionID: "early", GenerationID: "generation", Result: dropped}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-subscription:
		if result.Completed {
			t.Fatalf("subscription succeeded before SubscribeAck: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("pending subscription was not rejected by close")
	}
	select {
	case result := <-dropped:
		t.Fatalf("drop completed before delayed SubscribeAck and teardown: %#v", result)
	case <-time.After(30 * time.Millisecond):
	}
	select {
	case result := <-dropped:
		if !result.Completed {
			t.Fatalf("drop failed after projection teardown: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("drop did not observe projection termination")
	}
	assertProjectionGone(t, system, "subagents.agent.projection-test", projectionName("early", "generation"))
}

func TestProjectionRetriesNativePubSubAcksAfterMailboxDeadletters(t *testing.T) {
	var rejected atomic.Uint32
	system, agent := projectionTestSystem(t, func(value *AgentActor) {
		value.projectionMailbox = func() actor.Mailbox {
			return &rejectFirstPubSubAcksMailbox{Mailbox: actor.NewNonBlockingBoundedMailbox(4), rejected: &rejected}
		}
	})
	attached := projectionTestAttach(t, system, agent, "pubsub-acks")
	subscription := make(chan application.OperationResult, 1)
	if err := system.NoSender().Tell(context.Background(), agent, &application.SubscribeAgent{SessionID: "pubsub-acks", GenerationID: "generation", Principal: "caller", Handle: attached.Handle, Fence: attached.Fence, Result: subscription}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-subscription:
		if !result.Completed {
			t.Fatalf("subscription failed after SubscribeAck deadletter: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("scheduled subscribe retry did not recover from SubscribeAck deadletter")
	}
	dropped := make(chan application.OperationResult, 1)
	if err := system.NoSender().Tell(context.Background(), agent, &application.DropSession{SessionID: "pubsub-acks", GenerationID: "generation", Result: dropped}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-dropped:
		if !result.Completed {
			t.Fatalf("drop failed after UnsubscribeAck deadletter: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("scheduled unsubscribe retry did not recover from UnsubscribeAck deadletter")
	}
	if rejected.Load() != 3 {
		t.Fatalf("test did not deadletter both native PubSub acknowledgements: %02b", rejected.Load())
	}
	assertProjectionGone(t, system, "subagents.agent.projection-test", projectionName("pubsub-acks", "generation"))
}

func TestProjectionCloseRetriesAfterBoundedMailboxDeadletter(t *testing.T) {
	var rejected atomic.Int32
	system, agent := projectionTestSystem(t, func(value *AgentActor) {
		value.projectionMailbox = func() actor.Mailbox {
			return &rejectFirstCloseMailbox{Mailbox: actor.NewNonBlockingBoundedMailbox(4), rejected: &rejected}
		}
	})
	attached := projectionTestAttach(t, system, agent, "bounded")
	subscription := make(chan application.OperationResult, 1)
	if err := system.NoSender().Tell(context.Background(), agent, &application.SubscribeAgent{SessionID: "bounded", GenerationID: "generation", Principal: "caller", Handle: attached.Handle, Fence: attached.Fence, Result: subscription}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-subscription:
		if !result.Completed {
			t.Fatalf("subscription failed: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("subscription did not wait for SubscribeAck")
	}

	dropped := make(chan application.OperationResult, 1)
	if err := system.NoSender().Tell(context.Background(), agent, &application.DropSession{SessionID: "bounded", GenerationID: "generation", Result: dropped}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-dropped:
		if !result.Completed {
			t.Fatalf("drop failed: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("scheduled close retry did not recover from mailbox deadletter")
	}
	if rejected.Load() != 1 {
		t.Fatalf("test did not force exactly one bounded-mailbox deadletter: %d", rejected.Load())
	}
	assertProjectionGone(t, system, "subagents.agent.projection-test", projectionName("bounded", "generation"))
}

func projectionTestSystem(t *testing.T, configure func(*AgentActor)) (actor.ActorSystem, *actor.PID) {
	t.Helper()
	ctx := context.Background()
	system, err := actor.NewActorSystem("projection-race-test", actor.WithPubSub(), actor.WithMessageRetention(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if err := system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		stopCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = system.Stop(stopCtx)
	})
	registration := &application.RegisterAgent{AgentID: "projection-test", AllowedCapability: []string{"observe"}}
	value := NewAgentActor(registration)
	configure(value)
	pid, err := system.Spawn(ctx, "projection-test-agent", value)
	if err != nil {
		t.Fatal(err)
	}
	return system, pid
}

func projectionTestAttach(t *testing.T, system actor.ActorSystem, agent *actor.PID, session string) *application.AttachResult {
	t.Helper()
	value, err := system.NoSender().Ask(context.Background(), agent, &application.AttachAgent{SessionID: session, GenerationID: "generation", Principal: "caller", RequestedCapabilities: []string{"observe"}, IssuedHandle: "handle"}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	return value.(*application.AttachResult)
}

func waitForActor(t *testing.T, system actor.ActorSystem, name string) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if _, err := system.ActorOf(context.Background(), name); err == nil {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("actor %s did not start", name)
}

func assertProjectionGone(t *testing.T, system actor.ActorSystem, topic, name string) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		_, actorErr := system.ActorOf(context.Background(), name)
		stats, statsErr := system.TopicStats(context.Background(), topic, time.Second)
		if actorErr != nil && statsErr == nil && stats.LocalSubscriberCount() == 0 {
			return
		}
		time.Sleep(time.Millisecond)
	}
	_, actorErr := system.ActorOf(context.Background(), name)
	stats, _ := system.TopicStats(context.Background(), topic, time.Second)
	t.Fatalf("projection teardown incomplete: actor=%v subscribers=%d", actorErr, stats.LocalSubscriberCount())
}
