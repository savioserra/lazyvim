package actors_test

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
)

type cursorAckStore struct {
	mu      sync.Mutex
	records []application.DurableHostedRecord
	notify  chan struct{}
}

func (s *cursorAckStore) Save(_ context.Context, r application.DurableHostedRecord) error {
	s.mu.Lock()
	s.records = append(s.records, r)
	s.mu.Unlock()
	select {
	case s.notify <- struct{}{}:
	default:
	}
	return nil
}
func (*cursorAckStore) Remove(context.Context, string) error { return nil }

func (s *cursorAckStore) last() application.DurableHostedRecord {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.records[len(s.records)-1]
}

func (s *cursorAckStore) waitForSave(t *testing.T) application.DurableHostedRecord {
	t.Helper()
	select {
	case <-s.notify:
		return s.last()
	case <-time.After(time.Second):
		t.Fatal("expected durable save did not start")
		return application.DurableHostedRecord{}
	}
}

func TestAckCursorCommitsContiguouslyWithBoundedGapBuffer(t *testing.T) {
	b := newBridgeHarness(t, "ack-cursor", "bravo", "alpha")
	completion := make(chan application.BridgeIntentResult, 1)
	if r := b.ask(b.intent(application.BridgeMessageTell, "alpha", "tell-1", "chain-1", 1)).(*application.BridgeIntentResult); !r.Accepted {
		t.Fatalf("first tell rejected: %#v", r)
	}
	if r := b.ask(b.intent(application.BridgeMessageTell, "alpha", "tell-2", "chain-2", 2)).(*application.BridgeIntentResult); !r.Accepted {
		t.Fatalf("second tell rejected: %#v", r)
	}
	ask := b.intent(application.BridgeMessageAsk, "alpha", "ask-3", "chain-3", 3)
	ask.Completion = completion
	if r := b.ask(ask).(*application.BridgeIntentResult); !r.Accepted || !r.AwaitingAck {
		t.Fatalf("third ask rejected: %#v", r)
	}
	deliveries := b.poll().Deliveries
	if len(deliveries) != 3 {
		t.Fatalf("expected three retained deliveries: %#v", deliveries)
	}
	first, second, third := deliveries[0], deliveries[1], deliveries[2]
	ack := func(delivery application.BridgeDelivery) *application.BridgeDeliveryAckResult {
		return b.ask(identityAck(b.session, b.generation, b.principal, b.handle, b.fence, "runtime-bravo", "pi-bravo", delivery, true, []byte("answer"))).(*application.BridgeDeliveryAckResult)
	}
	if result := ack(first); !result.Accepted || result.Cursor != 1 {
		t.Fatalf("first ack must advance the cursor to 1: %#v", result)
	}
	// Acknowledging sequence 3 while sequence 2 is unacknowledged must buffer
	// without advancing the cursor past 1 and must keep sequence 2 replayable.
	buffered := ack(third)
	if !buffered.Accepted || buffered.Cursor != 1 {
		t.Fatalf("gap acknowledgement must not advance the cursor: %#v", buffered)
	}
	replay := b.poll().Deliveries
	if len(replay) != 2 || replay[0].Sequence != second.Sequence || replay[1].Sequence != third.Sequence {
		t.Fatalf("gap acknowledgement retired pending deliveries from replay: %#v", replay)
	}
	select {
	case <-completion:
		t.Fatal("buffered acknowledgement emitted its dependent completion early")
	default:
	}
	// Committing sequence 2 drains the buffered sequence 3 in the same burst.
	committed := ack(second)
	if !committed.Accepted || committed.Cursor != 3 {
		t.Fatalf("contiguous commit must drain the buffered acknowledgement: %#v", committed)
	}
	if len(b.poll().Deliveries) != 0 {
		t.Fatal("committed deliveries remained replayable")
	}
	select {
	case result := <-completion:
		if !result.Completed || string(result.Result) != "answer" {
			t.Fatalf("drained dependent completion is wrong: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("drained dependent completion missing")
	}
	select {
	case <-completion:
		t.Fatal("dependent completion emitted more than once")
	default:
	}
	// Duplicates return the retained terminal on exact identity match; a
	// mismatched identity collides and fails closed.
	if duplicate := ack(second); !duplicate.Accepted || duplicate.Cursor != 3 {
		t.Fatalf("idempotent duplicate acknowledgement must return the retained terminal: %#v", duplicate)
	}
	select {
	case <-completion:
		t.Fatal("duplicate acknowledgement re-emitted the dependent completion")
	default:
	}
	forged := identityAck(b.session, b.generation, b.principal, b.handle, b.fence, "runtime-bravo", "pi-bravo", second, true, []byte("answer"))
	forged.CompletionKey = "forged-completion-key"
	if collision := b.ask(forged).(*application.BridgeDeliveryAckResult); collision.Accepted {
		t.Fatalf("duplicate acknowledgement with mismatched identity was accepted: %#v", collision)
	}
}

func awaitResult[T any](t *testing.T, results chan T, what string) T {
	t.Helper()
	select {
	case value := <-results:
		return value
	case <-time.After(2 * time.Second):
		t.Fatalf("%s timed out", what)
		var zero T
		return zero
	}
}

func TestBufferedAckSurvivesRestartAndDrainsAfterCursorCatchUp(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("ack-cursor-durable")
	if err != nil {
		t.Fatal(err)
	}
	if err = system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		stop, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = system.Stop(stop)
	})
	store := &cursorAckStore{notify: make(chan struct{}, 8)}
	writer, err := system.Spawn(ctx, "cursor-writer", &actors.HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.State, binding.BridgeReady, binding.RuntimeID, binding.Incarnation = application.HostedPiRuntimeReady, true, "runtime-bravo", 1
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "bravo", Binding: binding, AgentState: application.DurableAgentState{BridgeReady: true}}
	pid, err := system.Spawn(ctx, "cursor-agent", actors.NewBridgeDeliveryFixtureAgent(&application.RegisterAgent{AgentID: "bravo", HostedPiRuntime: binding, AllowedCapability: []string{"send", "ask", "hosted_bridge"}, PersistencePID: writer, DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	// Durable agents release their replies through result channels after the
	// fsync completes, so drive attach/connect/intent/ack via typed channels.
	tell := func(message any) { _ = system.NoSender().Tell(ctx, pid, message) }
	awaitAttach := func(results chan application.AttachResult, what string) application.AttachResult {
		return awaitResult(t, results, what)
	}
	awaitBridge := func(results chan application.BridgeResult, what string) application.BridgeResult {
		return awaitResult(t, results, what)
	}
	awaitIntent := func(results chan application.BridgeIntentResult, what string) application.BridgeIntentResult {
		return awaitResult(t, results, what)
	}
	awaitAck := func(results chan application.BridgeDeliveryAckResult, what string) application.BridgeDeliveryAckResult {
		return awaitResult(t, results, what)
	}
	attachResults := make(chan application.AttachResult, 1)
	tell(&application.AttachAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", RequestedCapabilities: []string{"send", "ask", "hosted_bridge"}, IssuedHandle: "handle", Result: attachResults})
	attached := awaitAttach(attachResults, "attach")
	bridgeResults := make(chan application.BridgeResult, 1)
	tell(&application.BridgeConnect{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", AgentID: "bravo", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime-bravo", Incarnation: 1, PiSessionID: "pi-bravo", Result: bridgeResults})
	if connected := awaitBridge(bridgeResults, "connect"); !connected.Accepted {
		t.Fatalf("connect rejected: %#v", connected)
	}
	intent := func(dedupe, chain string, sequence uint64) *application.BridgeIntent {
		return &application.BridgeIntent{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: attached.Handle, Fence: attached.Fence, SourceAgentID: "alpha", TargetAgentID: "bravo", RequestID: "request-" + dedupe, RequiredCapability: "send", DedupeID: dedupe, ChainID: chain, Deadline: time.Now().Add(time.Minute), HopLimit: 4, SourceMutationSequence: sequence, Mode: application.BridgeMessageTell, Payload: []byte("payload")}
	}
	for _, item := range []struct {
		dedupe, chain string
		sequence      uint64
	}{{"one", "chain-one", 1}, {"two", "chain-two", 2}} {
		receipt := make(chan application.BridgeIntentResult, 1)
		message := intent(item.dedupe, item.chain, item.sequence)
		message.Receipt = receipt
		tell(message)
		if r := awaitIntent(receipt, "intent "+item.dedupe); !r.Accepted {
			t.Fatalf("intent %s rejected: %#v", item.dedupe, r)
		}
		store.waitForSave(t)
	}
	poll, err := system.NoSender().Ask(ctx, pid, &application.PollBridge{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: attached.Handle, Fence: attached.Fence, MaxItems: 8}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	deliveries := poll.(*application.BridgePollResult).Deliveries
	if len(deliveries) != 2 {
		t.Fatalf("expected two deliveries: %#v", deliveries)
	}
	ackResults := make(chan application.BridgeDeliveryAckResult, 4)
	bufferedAck := identityAck("session", "generation", "hosted:alpha", attached.Handle, attached.Fence, "runtime-bravo", "pi-bravo", deliveries[1], true, nil)
	bufferedAck.Completion = ackResults
	tell(bufferedAck)
	if result := awaitAck(ackResults, "buffered ack"); !result.Accepted || result.Cursor != 0 {
		t.Fatalf("gap acknowledgement was not buffered with cursor 0: %#v", result)
	}
	persisted := store.waitForSave(t)
	if persisted.AgentState.AckCursor != 0 || len(persisted.AgentState.AckGapBuffer) != 1 || persisted.AgentState.AckGapBuffer[0].Sequence != deliveries[1].Sequence {
		t.Fatalf("buffered acknowledgement was not durably retained: %#v", persisted.AgentState)
	}
	// Reload models a daemon restart: the buffered acknowledgement and both
	// retained deliveries must restore, and the missing contiguous
	// acknowledgement then drains the buffered one.
	persisted.Binding = binding
	reloaded, err := system.Spawn(ctx, "cursor-agent-reloaded", actors.NewBridgeDeliveryFixtureAgent(&application.RegisterAgent{AgentID: "bravo", HostedPiRuntime: binding, AllowedCapability: []string{"send", "ask", "hosted_bridge"}, DurableRecord: &persisted}))
	if err != nil {
		t.Fatal(err)
	}
	tellReloaded := func(message any) { _ = system.NoSender().Tell(ctx, reloaded, message) }
	state := persisted.AgentState
	if len(state.Attachments) != 1 {
		t.Fatalf("expected a restored attachment: %#v", state.Attachments)
	}
	restored := state.Attachments[0]
	catchUpResults := make(chan application.BridgeDeliveryAckResult, 1)
	catchUp := identityAck(state.BridgeSession, state.BridgeGeneration, state.BridgePrincipal, restored.Handle, restored.Fence, "runtime-bravo", state.BridgePiSession, deliveries[0], true, nil)
	catchUp.Completion = catchUpResults
	tellReloaded(catchUp)
	if result := awaitAck(catchUpResults, "catch-up ack"); !result.Accepted || result.Cursor != 2 {
		t.Fatalf("reloaded cursor did not drain the buffered acknowledgement: %#v", result)
	}
	afterValue, err := system.NoSender().Ask(ctx, reloaded, &application.PollBridge{SessionID: state.BridgeSession, GenerationID: state.BridgeGeneration, Principal: state.BridgePrincipal, Handle: restored.Handle, Fence: restored.Fence, MaxItems: 8}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if after := afterValue.(*application.BridgePollResult); len(after.Deliveries) != 0 {
		t.Fatalf("drained deliveries remained replayable after reload: %#v", after)
	}
}
