package actors_test

import (
	"context"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
)

// identityAckIncarnation stamps an acknowledgement with an explicit runtime
// incarnation, for bindings that changed incarnation mid-queue.
func identityAckIncarnation(sessionID, generationID, principal, handle string, fence uint64, runtimeID string, incarnation uint64, piSessionID string, delivery application.BridgeDelivery, delivered bool, result []byte) *application.BridgeDeliveryAck {
	return &application.BridgeDeliveryAck{SessionID: sessionID, GenerationID: generationID, Principal: principal, Handle: handle, Fence: fence, Sequence: delivery.Sequence, DedupeID: delivery.DedupeID, Delivered: delivered, Result: result, RuntimeID: runtimeID, Incarnation: incarnation, PiSessionID: piSessionID, Kind: application.BridgeDeliveryKindLabel(delivery.Kind), SourceScope: delivery.SourceScope, CompletionKey: delivery.CompletionKey}
}

// TestAckCursorRebasesPastLegacyRetiredSequences models the deployed incident
// exactly: durable sequences from prior incarnations and legacy records are
// retired or dropped at restore without ever advancing the contiguous
// acknowledgement baseline. A fresh delivery above them must commit its
// identity-valid acknowledgement immediately — never buffer behind the
// phantom gap of dropped predecessors that no client can ever acknowledge —
// and the retired delivery must leave the replay surface so the bridge stops
// re-sending it and the client stops re-acknowledging it.
func TestAckCursorRebasesPastLegacyRetiredSequences(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("ack-cursor-legacy-rebase", goakt.WithPubSub(), goakt.WithMessageRetention(time.Minute))
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
	store := &cursorAckStore{notify: make(chan struct{}, 16)}
	writer, err := system.Spawn(ctx, "legacy-rebase-writer", &actors.HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.State, binding.BridgeReady, binding.RuntimeID, binding.Incarnation = application.HostedPiRuntimeReady, true, "runtime-bravo", 1
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "bravo", Binding: binding, AgentState: application.DurableAgentState{BridgeReady: true}}
	pid, err := system.Spawn(ctx, "legacy-rebase-agent", actors.NewAgentActor(&application.RegisterAgent{AgentID: "bravo", HostedPiRuntime: binding, AllowedCapability: []string{"send", "ask", "hosted_bridge"}, PersistencePID: writer, DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	tell := func(target *goakt.PID, message any) { _ = system.NoSender().Tell(ctx, target, message) }
	attachResults := make(chan application.AttachResult, 1)
	tell(pid, &application.AttachAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", RequestedCapabilities: []string{"send", "ask", "hosted_bridge"}, IssuedHandle: "handle", Result: attachResults})
	attached := awaitResult(t, attachResults, "attach")
	if !attached.Completed {
		t.Fatalf("attach failed: %#v", attached)
	}
	bridgeResults := make(chan application.BridgeResult, 1)
	tell(pid, &application.BridgeConnect{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", AgentID: "bravo", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime-bravo", Incarnation: 1, PiSessionID: "pi-bravo", Result: bridgeResults})
	if connected := awaitResult(t, bridgeResults, "connect"); !connected.Accepted {
		t.Fatalf("connect rejected: %#v", connected)
	}
	intent := func(mode application.BridgeMessageMode, dedupe, chain string, sequence uint64) chan application.BridgeIntentResult {
		receipt := make(chan application.BridgeIntentResult, 1)
		capability := "ask"
		if mode == application.BridgeMessageTell {
			capability = "send"
		}
		tell(pid, &application.BridgeIntent{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: attached.Handle, Fence: attached.Fence, SourceAgentID: "alpha", TargetAgentID: "bravo", RequestID: "request-" + dedupe, RequiredCapability: capability, DedupeID: dedupe, ChainID: chain, Deadline: time.Now().Add(time.Minute), HopLimit: 4, SourceMutationSequence: sequence, Mode: mode, Payload: []byte("wake up"), Receipt: receipt})
		return receipt
	}
	// Queue three notification deliveries whose sequences will be retired as
	// legacy identity-less records at restore: the phantom predecessors. Only
	// one model task may be live at a time, so the queue mixes notifications
	// with at most one prompt.
	for _, item := range []struct {
		dedupe, chain string
		sequence      uint64
	}{{"legacy-one", "chain-one", 1}, {"legacy-two", "chain-two", 2}, {"legacy-three", "chain-three", 3}} {
		if result := awaitResult(t, intent(application.BridgeMessageTell, item.dedupe, item.chain, item.sequence), "legacy tell "+item.dedupe); !result.Accepted {
			t.Fatalf("legacy tell %s rejected: %#v", item.dedupe, result)
		}
	}
	store.waitForSave(t)
	poll := func(target *goakt.PID) []application.BridgeDelivery {
		value, err := system.NoSender().Ask(ctx, target, &application.PollBridge{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: attached.Handle, Fence: attached.Fence, MaxItems: 64}, 2*time.Second)
		if err != nil {
			t.Fatal(err)
		}
		return value.(*application.BridgePollResult).Deliveries
	}
	if deliveries := poll(pid); len(deliveries) != 3 {
		t.Fatalf("expected three queued deliveries: %#v", deliveries)
	}
	// Reload onto the incident shape: the three retained sequences are legacy
	// identity-less records whose owning scopes no longer resolve, so the
	// restore drops them without any acknowledgement ever committing.
	persisted := store.last()
	persisted.Binding = binding
	for index := range persisted.AgentState.BridgeDeliveries {
		persisted.AgentState.BridgeDeliveries[index].SourceScope = ""
		persisted.AgentState.BridgeDeliveries[index].CompletionKey = ""
	}
	persisted.AgentState.DeliverySources = nil
	persisted.AgentState.AckCursor = 0
	persisted.AgentState.AckGapBuffer = nil
	reloaded, err := system.Spawn(ctx, "legacy-rebase-reloaded", actors.NewAgentActor(&application.RegisterAgent{AgentID: "bravo", HostedPiRuntime: binding, AllowedCapability: []string{"send", "ask", "hosted_bridge"}, DurableRecord: &persisted}))
	if err != nil {
		t.Fatal(err)
	}
	if deliveries := poll(reloaded); len(deliveries) != 0 {
		t.Fatalf("legacy identity-less deliveries were served after reload: %#v", deliveries)
	}
	// Fresh work above the dropped predecessors: its acknowledgement must
	// commit immediately with the cursor advancing to its own sequence.
	freshCompletion := make(chan application.BridgeIntentResult, 2)
	freshReceipt := make(chan application.BridgeIntentResult, 1)
	tell(reloaded, &application.BridgeIntent{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: attached.Handle, Fence: attached.Fence, SourceAgentID: "alpha", TargetAgentID: "bravo", RequestID: "request-fresh", RequiredCapability: "ask", DedupeID: "fresh-dedupe", ChainID: "fresh-chain", Deadline: time.Now().Add(time.Minute), HopLimit: 4, SourceMutationSequence: 4, Mode: application.BridgeMessageAsk, Payload: []byte("wake again"), Receipt: freshReceipt, Completion: freshCompletion})
	if result := awaitResult(t, freshReceipt, "fresh ask"); !result.Accepted {
		t.Fatalf("fresh ask rejected: %#v", result)
	}
	fresh := poll(reloaded)
	if len(fresh) != 1 || fresh[0].Sequence != 4 || !fresh[0].AckIdentityComplete() {
		t.Fatalf("fresh delivery above dropped predecessors is wrong: %#v", fresh)
	}
	ack := identityAck("session", "generation", "hosted:alpha", attached.Handle, attached.Fence, "runtime-bravo", "pi-bravo", fresh[0], true, []byte("FRESH-OK"))
	ack.Reason = "legacy-rebase-committed"
	ackResults := make(chan application.BridgeDeliveryAckResult, 4)
	ack.Completion = ackResults
	tell(reloaded, ack)
	committed := awaitResult(t, ackResults, "fresh ack")
	if !committed.Accepted || committed.Cursor != 4 {
		t.Fatalf("acknowledgement above dropped predecessors must commit immediately: %#v", committed)
	}
	if committed.Reason == "acknowledgement buffered behind cursor gap" {
		t.Fatalf("acknowledgement buffered behind retired predecessors: %#v", committed)
	}
	// One acknowledgement retires the delivery: the replay surface stays
	// empty, so the bridge cannot re-send it and the client cannot loop.
	if deliveries := poll(reloaded); len(deliveries) != 0 {
		t.Fatalf("committed delivery stayed replayable: %#v", deliveries)
	}
	terminal := awaitResult(t, freshCompletion, "fresh completion")
	if !terminal.Completed || string(terminal.Result) != "FRESH-OK" {
		t.Fatalf("fresh completion is wrong: %#v", terminal)
	}
	// A replayed acknowledgement returns the retained terminal without
	// re-effects: same cursor, retained reason, no second completion.
	for range 3 {
		replay := identityAck("session", "generation", "hosted:alpha", attached.Handle, attached.Fence, "runtime-bravo", "pi-bravo", fresh[0], true, []byte("FRESH-OK"))
		replay.Reason = "legacy-rebase-committed"
		replay.Completion = ackResults
		tell(reloaded, replay)
		retained := awaitResult(t, ackResults, "replayed ack")
		if !retained.Accepted || retained.Cursor != 4 || retained.Reason != "legacy-rebase-committed" {
			t.Fatalf("replayed acknowledgement must return the retained terminal: %#v", retained)
		}
	}
	select {
	case extra := <-freshCompletion:
		t.Fatalf("replayed acknowledgement re-emitted the completion: %#v", extra)
	default:
	}
}

// TestAckCursorRebasesAcrossIncarnationChangeMidQueue proves the cursor and
// gap buffer are scoped to the current bridge binding and runtime
// incarnation: an incarnation change mid-queue retires every delivery
// terminally, discards acknowledgements buffered under the retired identity,
// and durably advances the baseline past everything it dropped, so the next
// incarnation's first acknowledgement commits immediately.
func TestAckCursorRebasesAcrossIncarnationChangeMidQueue(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("ack-cursor-incarnation-rebase", goakt.WithPubSub(), goakt.WithMessageRetention(time.Minute))
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
	store := &cursorAckStore{notify: make(chan struct{}, 16)}
	writer, err := system.Spawn(ctx, "incarnation-rebase-writer", &actors.HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.State, binding.BridgeReady, binding.RuntimeID, binding.Incarnation = application.HostedPiRuntimeDegraded, true, "runtime-bravo", 1
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "bravo", Binding: binding, AgentState: application.DurableAgentState{BridgeReady: true}}
	pid, err := system.Spawn(ctx, "incarnation-rebase-agent", actors.NewAgentActor(&application.RegisterAgent{AgentID: "bravo", HostedPiRuntime: binding, AllowedCapability: []string{"send", "ask", "hosted_bridge"}, PersistencePID: writer, DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	tell := func(message any) { _ = system.NoSender().Tell(ctx, pid, message) }
	attachResults := make(chan application.AttachResult, 1)
	tell(&application.AttachAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", RequestedCapabilities: []string{"send", "ask", "hosted_bridge"}, IssuedHandle: "handle", Result: attachResults})
	attached := awaitResult(t, attachResults, "attach")
	if !attached.Completed {
		t.Fatalf("attach failed: %#v", attached)
	}
	bridgeResults := make(chan application.BridgeResult, 1)
	tell(&application.BridgeConnect{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", AgentID: "bravo", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime-bravo", Incarnation: 1, PiSessionID: "pi-bravo", Result: bridgeResults})
	if connected := awaitResult(t, bridgeResults, "connect"); !connected.Accepted {
		t.Fatalf("connect rejected: %#v", connected)
	}
	intent := func(mode application.BridgeMessageMode, dedupe, chain string, sequence uint64, completion chan application.BridgeIntentResult) chan application.BridgeIntentResult {
		receipt := make(chan application.BridgeIntentResult, 1)
		capability := "ask"
		if mode == application.BridgeMessageTell {
			capability = "send"
		}
		tell(&application.BridgeIntent{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: attached.Handle, Fence: attached.Fence, SourceAgentID: "alpha", TargetAgentID: "bravo", RequestID: "request-" + dedupe, RequiredCapability: capability, DedupeID: dedupe, ChainID: chain, Deadline: time.Now().Add(time.Minute), HopLimit: 4, SourceMutationSequence: sequence, Mode: mode, Payload: []byte("wake up"), Receipt: receipt, Completion: completion})
		return receipt
	}
	if result := awaitResult(t, intent(application.BridgeMessageTell, "first", "chain-first", 1, nil), "first tell"); !result.Accepted {
		t.Fatalf("first tell rejected: %#v", result)
	}
	secondCompletion := make(chan application.BridgeIntentResult, 2)
	if result := awaitResult(t, intent(application.BridgeMessageAsk, "second", "chain-second", 2, secondCompletion), "second ask"); !result.Accepted {
		t.Fatalf("second ask rejected: %#v", result)
	}
	poll := func() []application.BridgeDelivery {
		value, err := system.NoSender().Ask(ctx, pid, &application.PollBridge{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: attached.Handle, Fence: attached.Fence, MaxItems: 64}, 2*time.Second)
		if err != nil {
			t.Fatal(err)
		}
		return value.(*application.BridgePollResult).Deliveries
	}
	deliveries := poll()
	if len(deliveries) != 2 {
		t.Fatalf("expected two queued deliveries: %#v", deliveries)
	}
	// Acknowledge the higher sequence first: it buffers behind the live
	// predecessor under the current binding identity.
	ackResults := make(chan application.BridgeDeliveryAckResult, 4)
	buffered := identityAck("session", "generation", "hosted:alpha", attached.Handle, attached.Fence, "runtime-bravo", "pi-bravo", deliveries[1], true, []byte("SECOND-OK"))
	buffered.Completion = ackResults
	tell(buffered)
	if result := awaitResult(t, ackResults, "buffered ack"); !result.Accepted || result.Cursor != 0 || result.Reason != "acknowledgement buffered behind cursor gap" {
		t.Fatalf("acknowledgement was not buffered behind the live predecessor: %#v", result)
	}
	// The durable confirm already released the acknowledgement response, so
	// the latest record is stable; drain pending save notifications so the
	// next wait observes only the retirement's own persist.
	retiredRecord := func() application.DurableAgentState { return store.last().AgentState }
	if state := retiredRecord(); state.AckCursor != 0 || len(state.AckGapBuffer) != 1 || state.AckGapBuffer[0].Sequence != 2 {
		t.Fatalf("buffered acknowledgement was not durably retained: %#v", state)
	}
	drainSaves := func() {
		for {
			select {
			case <-store.notify:
			default:
				return
			}
		}
	}
	drainSaves()
	// Incarnation change mid-queue: every delivery retires terminally and the
	// acknowledgement scope must rebase to the new incarnation.
	tell(&application.HostedPiRuntimeStateChanged{AgentID: "bravo", Binding: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, BridgeReady: true, RuntimeID: "runtime-bravo", Incarnation: 2}})
	retired := store.waitForSave(t)
	if len(retired.AgentState.BridgeDeliveries) != 0 || retired.AgentState.AckCursor != 2 || len(retired.AgentState.AckGapBuffer) != 0 {
		t.Fatalf("incarnation retirement did not durably rebase the acknowledgement cursor and gap buffer: %#v", retired.AgentState)
	}
	if retired.AgentState.BridgeSession != "" {
		t.Fatalf("incarnation retirement did not durably wipe the binding: %#v", retired.AgentState)
	}
	// The queued model task terminally resolved exactly once through the
	// retirement; the notification predecessor has no completion channel.
	terminal := awaitResult(t, secondCompletion, "retirement completion")
	if terminal.Completed || terminal.Reason != "hosted runtime incarnation retired" {
		t.Fatalf("retirement completion is wrong: %#v", terminal)
	}
	select {
	case extra := <-secondCompletion:
		t.Fatalf("retirement completion emitted twice: %#v", extra)
	default:
	}
	// A replay of the buffered acknowledgement from the retired identity must
	// fail closed instead of being accepted into another unfillable buffer.
	tell(buffered)
	replayedStale := awaitResult(t, ackResults, "stale replayed ack")
	if replayedStale.Accepted {
		t.Fatalf("acknowledgement from the retired incarnation was accepted: %#v", replayedStale)
	}
	// The next incarnation reconnects with a fresh pi-session identity.
	tell(&application.BridgeConnect{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", AgentID: "bravo", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime-bravo", Incarnation: 2, PiSessionID: "pi-bravo-next", Result: bridgeResults})
	if reconnected := awaitResult(t, bridgeResults, "reconnect"); !reconnected.Accepted {
		t.Fatalf("reconnect under the new incarnation rejected: %#v", reconnected)
	}
	reconnectedState := store.last().AgentState
	if reconnectedState.BridgePiSession != "pi-bravo-next" || reconnectedState.AckCursor != 2 {
		t.Fatalf("reconnect did not persist the new acknowledgement scope: %#v", reconnectedState)
	}
	// Fresh work under the new incarnation commits its acknowledgement
	// immediately: the cursor never buffers behind the retired predecessors.
	// The new incarnation also starts a fresh mutation-scope ledger, while the
	// delivery sequence stays globally monotonic.
	nextCompletion := make(chan application.BridgeIntentResult, 2)
	if result := awaitResult(t, intent(application.BridgeMessageAsk, "next", "chain-next", 1, nextCompletion), "next ask"); !result.Accepted {
		t.Fatalf("next ask rejected: %#v", result)
	}
	next := poll()
	if len(next) != 1 || next[0].Sequence != 3 {
		t.Fatalf("fresh delivery under the new incarnation is wrong: %#v", next)
	}
	nextAck := identityAckIncarnation("session", "generation", "hosted:alpha", attached.Handle, attached.Fence, "runtime-bravo", 2, "pi-bravo-next", next[0], true, []byte("NEXT-OK"))
	nextAck.Reason = "incarnation-rebased"
	nextAck.Completion = ackResults
	tell(nextAck)
	committed := awaitResult(t, ackResults, "next ack")
	if !committed.Accepted || committed.Cursor != 3 || committed.Reason == "acknowledgement buffered behind cursor gap" {
		t.Fatalf("new incarnation acknowledgement did not commit immediately: %#v", committed)
	}
	if deliveries := poll(); len(deliveries) != 0 {
		t.Fatalf("committed delivery stayed replayable: %#v", deliveries)
	}
	nextTerminal := awaitResult(t, nextCompletion, "next completion")
	if !nextTerminal.Completed || string(nextTerminal.Result) != "NEXT-OK" {
		t.Fatalf("next completion is wrong: %#v", nextTerminal)
	}
}

// TestDeadlineRetirementAdvancesCursorAndDrainsBufferedAck closes the
// mid-queue retirement path: a deadline expiry that drops a lower sequence
// must advance the contiguous baseline past it and automatically drain the
// already-buffered acknowledgement for the next sequence, with no client
// re-acknowledgement needed and no re-effects on replay.
func TestDeadlineRetirementAdvancesCursorAndDrainsBufferedAck(t *testing.T) {
	b := newBridgeHarness(t, "ack-cursor-deadline-rebase", "bravo", "alpha")
	// The predecessor is a short-deadline notification so exactly one model
	// task (the successor prompt) is live at a time.
	first := b.intent(application.BridgeMessageTell, "alpha", "tell-short", "chain-short", 1)
	first.Deadline = time.Now().Add(300 * time.Millisecond)
	if r := b.ask(first).(*application.BridgeIntentResult); !r.Accepted {
		t.Fatalf("short tell rejected: %#v", r)
	}
	secondCompletion := make(chan application.BridgeIntentResult, 2)
	second := b.intent(application.BridgeMessageAsk, "alpha", "ask-long", "chain-long", 2)
	second.Completion = secondCompletion
	if r := b.ask(second).(*application.BridgeIntentResult); !r.Accepted {
		t.Fatalf("long ask rejected: %#v", r)
	}
	deliveries := b.poll().Deliveries
	if len(deliveries) != 2 {
		t.Fatalf("expected two deliveries: %#v", deliveries)
	}
	ackResults := make(chan application.BridgeDeliveryAckResult, 4)
	buffered := identityAck(b.session, b.generation, b.principal, b.handle, b.fence, "runtime-bravo", "pi-bravo", deliveries[1], true, []byte("SECOND-OK"))
	buffered.Reason = "deadline-drain-committed"
	buffered.Completion = ackResults
	if result := b.ask(buffered).(*application.BridgeDeliveryAckResult); !result.Accepted || result.Cursor != 0 || result.Reason != "acknowledgement buffered behind cursor gap" {
		t.Fatalf("acknowledgement was not buffered behind the live predecessor: %#v", result)
	}
	// The predecessor's deadline retirement must drain the buffered
	// acknowledgement for the successor without any client action.
	drained := awaitResult(t, secondCompletion, "drained buffered acknowledgement completion")
	if !drained.Completed || string(drained.Result) != "SECOND-OK" {
		t.Fatalf("buffered acknowledgement was not drained by the retirement: %#v", drained)
	}
	select {
	case extra := <-secondCompletion:
		t.Fatalf("drained completion emitted twice: %#v", extra)
	default:
	}
	if replay := b.poll().Deliveries; len(replay) != 0 {
		t.Fatalf("retired and committed deliveries stayed replayable: %#v", replay)
	}
	// Replaying the drained acknowledgement returns the retained terminal
	// without re-effects and proves the cursor advanced past the drop.
	for range 3 {
		replay := identityAck(b.session, b.generation, b.principal, b.handle, b.fence, "runtime-bravo", "pi-bravo", deliveries[1], true, []byte("SECOND-OK"))
		replay.Reason = "deadline-drain-committed"
		replay.Completion = ackResults
		retained := b.ask(replay).(*application.BridgeDeliveryAckResult)
		if !retained.Accepted || retained.Cursor != 2 || retained.Reason != "deadline-drain-committed" {
			t.Fatalf("replayed acknowledgement must return the retained terminal with the advanced cursor: %#v", retained)
		}
	}
	select {
	case extra := <-secondCompletion:
		t.Fatalf("replayed acknowledgement re-emitted the completion: %#v", extra)
	default:
	}
}
