package application

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

func testClientActorState(t *testing.T) DurableClientActorContractState {
	t.Helper()
	state, err := NewDurableClientActorContractState("client", ClientActorExecutorFence{ActorEpoch: 7, ExecutorGeneration: 11, LeaseID: "lease"})
	if err != nil {
		t.Fatal(err)
	}
	return state
}

func admitAssignedTurn(t *testing.T, state *DurableClientActorContractState, nonce string) DurableClientActorLogEntry {
	t.Helper()
	entry, admitted, err := state.AdmitUserTurnForThread(state.CurrentFence, "thread", nonce, []byte(`{"input":"hello"}`))
	if err != nil || !admitted {
		t.Fatalf("admission admitted=%v err=%v", admitted, err)
	}
	if err := state.AssignWorkToLease(entry.WorkID, state.CurrentFence); err != nil {
		t.Fatal(err)
	}
	return entry
}

func settleCompletionWork(t *testing.T, state *DurableClientActorContractState, workID string) DurableClientActorLogEntry {
	t.Helper()
	entry, err := state.AppendWork(ClientActorSemanticCompletion, workID, []byte(`{"summary":"done"}`))
	if err != nil {
		t.Fatal(err)
	}
	if err := state.AssignWorkToLease(entry.WorkID, state.CurrentFence); err != nil {
		t.Fatal(err)
	}
	if _, _, err := state.SettleWork(state.CurrentFence, entry.WorkID, entry.Family, true, []byte(`{"summary":"done"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	return entry
}

func settleIntrospectionForSource(t *testing.T, state *DurableClientActorContractState, source DurableClientActorLogEntry, workID string) DurableClientActorLogEntry {
	t.Helper()
	intro, err := state.AppendIntrospectionForSource(source.WorkID, workID, []byte(`{"decision":"continue"}`))
	if err != nil {
		t.Fatal(err)
	}
	if err := state.AssignWorkToLease(intro.WorkID, state.CurrentFence); err != nil {
		t.Fatal(err)
	}
	if _, _, err := state.SettleWork(state.CurrentFence, intro.WorkID, intro.Family, true, []byte(`{"decision":"continue"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	return intro
}

func TestClientActorConstructorRejectsEmptyBoundary(t *testing.T) {
	_, err := NewDurableClientActorContractState("", ClientActorExecutorFence{ActorEpoch: 1, ExecutorGeneration: 1, LeaseID: "lease"})
	if !errors.Is(err, ErrClientActorInvalidIdentifier) {
		t.Fatalf("empty actor err=%v, want invalid identifier", err)
	}
	_, err = NewDurableClientActorContractState("client", ClientActorExecutorFence{ActorEpoch: 1, ExecutorGeneration: 1})
	if !errors.Is(err, ErrClientActorInvalidBoundary) {
		t.Fatalf("empty lease err=%v, want invalid boundary", err)
	}
}

func TestClientActorZeroValueAndCorruptStateAreSafe(t *testing.T) {
	var zero DurableClientActorContractState
	if _, _, err := zero.AdmitUserTurn("nonce", []byte(`{}`)); !errors.Is(err, ErrClientActorCorruptState) {
		t.Fatalf("zero state err=%v, want corrupt", err)
	}
	state := testClientActorState(t)
	entry, _, err := state.AdmitUserTurn("nonce", []byte(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	state.Log = nil
	if _, _, err := state.AdmitUserTurn("nonce", []byte(`{}`)); !errors.Is(err, ErrClientActorCorruptState) {
		t.Fatalf("index/log divergence err=%v, want corrupt for %s", err, entry.WorkID)
	}
}

func TestClientActorAdmitUserTurnRequiresNonceAndDigestDedupe(t *testing.T) {
	state := testClientActorState(t)
	if _, _, err := state.AdmitUserTurn("", []byte(`{"input":"hello"}`)); !errors.Is(err, ErrClientActorInvalidIdentifier) {
		t.Fatalf("empty nonce err=%v, want invalid identifier", err)
	}
	first, admitted, err := state.AdmitUserTurn("nonce", []byte(`{"input":"hello"}`))
	if err != nil || !admitted {
		t.Fatalf("first admission admitted=%v err=%v", admitted, err)
	}
	duplicate, admitted, err := state.AdmitUserTurn("nonce", []byte(`{"input":"hello"}`))
	if err != nil || admitted || duplicate.WorkID != first.WorkID || duplicate.Sequence != first.Sequence {
		t.Fatalf("duplicate admission admitted=%v err=%v duplicate=%#v first=%#v", admitted, err, duplicate, first)
	}
	_, _, err = state.AdmitUserTurn("nonce", []byte(`{"input":"different"}`))
	if !errors.Is(err, ErrClientActorIdempotencyConflict) {
		t.Fatalf("same nonce different digest err=%v, want conflict", err)
	}
}

func TestClientActorDuplicateAdmissionPrivacyRunsBeforeReplay(t *testing.T) {
	state := testClientActorState(t)
	if _, _, err := state.AdmitUserTurn("nonce", []byte(`{"input":"hello"}`)); err != nil {
		t.Fatal(err)
	}
	_, _, err := state.AdmitUserTurn("nonce", []byte(`{"raw_reasoning":"secret"}`))
	if !errors.Is(err, ErrClientActorPrivacyCanary) {
		t.Fatalf("duplicate sensitive admission err=%v, want privacy", err)
	}
}

func TestClientActorAppendWorkRejectsInvalidDuplicateAndRestrictedFamilies(t *testing.T) {
	state := testClientActorState(t)
	if _, err := state.AppendWork(ClientActorSemanticAsk, "", []byte(`{}`)); !errors.Is(err, ErrClientActorInvalidIdentifier) {
		t.Fatalf("empty work id err=%v, want invalid identifier", err)
	}
	if _, err := state.AppendWork(ClientActorSemanticFamily("bogus"), "work:1", []byte(`{}`)); !errors.Is(err, ErrClientActorInvalidSemantic) {
		t.Fatalf("invalid family err=%v, want invalid semantic", err)
	}
	if _, err := state.AppendWork(ClientActorSemanticUserTurn, "work:1", []byte(`{}`)); !errors.Is(err, ErrClientActorInvalidSemantic) {
		t.Fatalf("direct user turn append err=%v, want invalid semantic", err)
	}
	if _, err := state.AppendWork(ClientActorSemanticPresentationAck, "ack:1", nil); !errors.Is(err, ErrClientActorPresentationAckOnly) {
		t.Fatalf("presentation append err=%v, want projection only", err)
	}
	if _, err := state.AppendWork(ClientActorSemanticAsk, "work:1", []byte(`{"ask":"work"}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := state.AppendWork(ClientActorSemanticAsk, "work:1", []byte(`{"ask":"work"}`)); !errors.Is(err, ErrClientActorDuplicateWork) {
		t.Fatalf("exact replay work id err=%v, want duplicate", err)
	}
	if _, err := state.AppendWork(ClientActorSemanticAsk, "work:1", []byte(`{"ask":"different"}`)); !errors.Is(err, ErrClientActorDuplicateWork) {
		t.Fatalf("same-family different-digest work id err=%v, want duplicate", err)
	}
	if _, err := state.AppendWork(ClientActorSemanticTell, "work:1", []byte(`{"tell":"overwrite"}`)); !errors.Is(err, ErrClientActorDuplicateWork) {
		t.Fatalf("different-family collision work id err=%v, want duplicate", err)
	}
}

func TestClientActorDurableLogStoresRedactedDigestOnly(t *testing.T) {
	state := testClientActorState(t)
	entry, admitted, err := state.AdmitUserTurn("nonce", []byte(`{"input":"hello"}`))
	if err != nil || !admitted {
		t.Fatalf("admission admitted=%v err=%v", admitted, err)
	}
	if entry.Content.Size == 0 || !entry.Content.Redacted || entry.Content.Digest != sha256.Sum256([]byte(`{"input":"hello"}`)) {
		t.Fatalf("unexpected content projection: %#v", entry.Content)
	}
	if len(state.Log) != 1 || state.Log[0].Content.Ref != "" || !state.Log[0].Content.Redacted {
		t.Fatalf("durable log did not retain redacted projection: %#v", state.Log)
	}
}

func TestClientActorSemanticFamiliesAreNotInterchangeable(t *testing.T) {
	state := testClientActorState(t)
	entry := admitAssignedTurn(t, &state, "nonce")
	_, _, err := state.SettleWork(state.CurrentFence, entry.WorkID, ClientActorSemanticAsk, true, []byte(`{"result":"ok"}`), ClientActorSettlementDigestFromJSON)
	if !errors.Is(err, ErrClientActorDuplicateSemantic) {
		t.Fatalf("SettleWork() err=%v, want semantic mismatch", err)
	}
}

func TestClientActorLogOrderAndDurableAdmissionBeforeExecution(t *testing.T) {
	state := testClientActorState(t)
	first, admitted, err := state.AdmitUserTurn("same", []byte(`{"input":"first"}`))
	if err != nil || !admitted {
		t.Fatalf("first admission admitted=%v err=%v", admitted, err)
	}
	duplicate, admitted, err := state.AdmitUserTurn("same", []byte(`{"input":"first"}`))
	if err != nil || admitted {
		t.Fatalf("duplicate admission admitted=%v err=%v", admitted, err)
	}
	second, err := state.AppendWork(ClientActorSemanticAsk, "ask:1", []byte(`{"ask":"work"}`))
	if err != nil {
		t.Fatal(err)
	}
	if first.Sequence != 1 || duplicate.Sequence != first.Sequence || second.Sequence != 2 || state.NextSequence != 3 {
		t.Fatalf("unexpected per-actor order: first=%d duplicate=%d second=%d next=%d", first.Sequence, duplicate.Sequence, second.Sequence, state.NextSequence)
	}
}

func TestClientActorSettlementValidatesFenceBeforePayloadParsing(t *testing.T) {
	state := testClientActorState(t)
	entry := admitAssignedTurn(t, &state, "nonce")
	parsed := 0
	stale := ClientActorExecutorFence{ActorEpoch: 7, ExecutorGeneration: 10, LeaseID: "lease-old"}
	_, _, err := state.SettleWork(stale, entry.WorkID, entry.Family, true, []byte(`not-json-and-must-not-parse`), func(raw []byte) ([32]byte, error) {
		parsed++
		return ClientActorSettlementDigestFromJSON(raw)
	})
	if !errors.Is(err, ErrClientActorStaleFence) || parsed != 0 {
		t.Fatalf("stale fence err=%v parsed=%d", err, parsed)
	}
}

func TestClientActorSettlementRequiresActiveWorkAssignment(t *testing.T) {
	state := testClientActorState(t)
	entry, _, err := state.AdmitUserTurnForThread(state.CurrentFence, "thread", "nonce", []byte(`{"input":"hello"}`))
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = state.SettleWork(state.CurrentFence, entry.WorkID, entry.Family, true, []byte(`{"result":"ok"}`), ClientActorSettlementDigestFromJSON)
	if !errors.Is(err, ErrClientActorUnassignedWork) {
		t.Fatalf("unassigned settle err=%v, want unassigned", err)
	}
	if err := state.AssignWorkToLease(entry.WorkID, state.CurrentFence); err != nil {
		t.Fatal(err)
	}
	other, _, err := state.AdmitUserTurnForThread(state.CurrentFence, "thread", "other", []byte(`{"input":"hello"}`))
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = state.SettleWork(state.CurrentFence, other.WorkID, other.Family, true, []byte(`{"result":"ok"}`), ClientActorSettlementDigestFromJSON)
	if !errors.Is(err, ErrClientActorUnassignedWork) {
		t.Fatalf("wrong-work-with-valid-fence err=%v, want unassigned", err)
	}
}

func TestClientActorSettlementIdempotencyBeforeSideEffectsAndPrivacyBeforeParse(t *testing.T) {
	state := testClientActorState(t)
	entry := admitAssignedTurn(t, &state, "nonce")
	payload := []byte(`{"result":"ok"}`)
	settlement, committed, err := state.SettleWork(state.CurrentFence, entry.WorkID, entry.Family, true, payload, ClientActorSettlementDigestFromJSON)
	if err != nil || !committed {
		t.Fatalf("first settlement committed=%v err=%v", committed, err)
	}
	if settlement.WorkSequence != entry.Sequence || settlement.SettlementSequence == 0 || settlement.SettlementHigh != entry.Sequence || settlement.ReplayEligible {
		t.Fatalf("settlement metadata incomplete: %#v", settlement)
	}
	beforeLog := len(state.Log)
	duplicate, committed, err := state.SettleWork(state.CurrentFence, entry.WorkID, entry.Family, true, payload, ClientActorSettlementDigestFromJSON)
	if err != nil || committed || duplicate != settlement || len(state.Log) != beforeLog {
		t.Fatalf("idempotent settlement changed state duplicate=%#v settlement=%#v committed=%v err=%v", duplicate, settlement, committed, err)
	}
	parsed := 0
	_, _, err = state.SettleWork(state.CurrentFence, entry.WorkID, entry.Family, true, []byte(`{"raw_reasoning":"do not parse"}`), func(raw []byte) ([32]byte, error) {
		parsed++
		return sha256.Sum256(raw), nil
	})
	if !errors.Is(err, ErrClientActorPrivacyCanary) || parsed != 0 {
		t.Fatalf("privacy-before-parse err=%v parsed=%d", err, parsed)
	}
}

func TestClientActorDeterministicContinuationEligibilityDedupeAndConflict(t *testing.T) {
	state := testClientActorState(t)
	if _, _, err := state.EnqueueSelfContinuationForThread("missing", "thread", 1, 0, []byte(`{"continue":"bounded"}`)); !errors.Is(err, ErrClientActorContinuationSource) {
		t.Fatalf("unknown source err=%v, want source ineligible", err)
	}
	entry := admitAssignedTurn(t, &state, "nonce")
	if _, _, err := state.SettleWork(state.CurrentFence, entry.WorkID, entry.Family, false, []byte(`{"result":"future-action"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	if _, _, err := state.EnqueueSelfContinuationForThread(entry.WorkID, "thread", 42, 0, []byte(`{"continue":"bounded"}`)); !errors.Is(err, ErrClientActorContinuationSource) {
		t.Fatalf("no introspection err=%v, want source ineligible", err)
	}
	intro := settleIntrospectionForSource(t, &state, entry, "intro:1")
	if err := state.MarkIntrospected(entry.WorkID, intro.Sequence); err != nil {
		t.Fatal(err)
	}
	if _, _, err := state.EnqueueSelfContinuationForThread(entry.WorkID, "other-thread", intro.Sequence, 0, []byte(`{"continue":"bounded"}`)); !errors.Is(err, ErrClientActorContinuationSource) {
		t.Fatalf("cross-thread err=%v, want source ineligible", err)
	}
	cont, enqueued, err := state.EnqueueSelfContinuationForThread(entry.WorkID, "thread", intro.Sequence, 0, []byte(`{"continue":"bounded"}`))
	if err != nil || !enqueued {
		t.Fatalf("enqueue enqueued=%v err=%v", enqueued, err)
	}
	dup, enqueued, err := state.EnqueueSelfContinuationForThread(entry.WorkID, "thread", intro.Sequence, 0, []byte(`{"continue":"bounded"}`))
	if err != nil || enqueued || dup.WorkID != cont.WorkID {
		t.Fatalf("duplicate continuation enqueued=%v err=%v dup=%#v cont=%#v", enqueued, err, dup, cont)
	}
	_, _, err = state.EnqueueSelfContinuationForThread(entry.WorkID, "thread", intro.Sequence, 0, []byte(`{"continue":"different"}`))
	if !errors.Is(err, ErrClientActorIdempotencyConflict) {
		t.Fatalf("same continuation key different digest err=%v, want conflict", err)
	}
	state.ContinuationPolicy.BudgetRemaining = 0
	if _, _, err := state.EnqueueSelfContinuationForThread(entry.WorkID, "thread", intro.Sequence, 1, []byte(`{"continue":"bounded"}`)); !errors.Is(err, ErrClientActorContinuationSource) {
		t.Fatalf("budget err=%v, want source ineligible", err)
	}
	state.ContinuationPolicy.BudgetRemaining = 1
	state.ContinuationPolicy.Deadline = time.Now().Add(-time.Second)
	if _, _, err := state.EnqueueSelfContinuationForThread(entry.WorkID, "thread", intro.Sequence, 2, []byte(`{"continue":"bounded"}`)); !errors.Is(err, ErrClientActorContinuationSource) {
		t.Fatalf("deadline err=%v, want source ineligible", err)
	}
}

func TestClientActorContinuationPrivacyRunsBeforeReplay(t *testing.T) {
	state := testClientActorState(t)
	entry := admitAssignedTurn(t, &state, "nonce")
	if _, _, err := state.SettleWork(state.CurrentFence, entry.WorkID, entry.Family, false, []byte(`{"result":"future-action"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	intro := settleIntrospectionForSource(t, &state, entry, "intro:privacy")
	if err := state.MarkIntrospected(entry.WorkID, intro.Sequence); err != nil {
		t.Fatal(err)
	}
	if _, _, err := state.EnqueueSelfContinuationForThread(entry.WorkID, "thread", intro.Sequence, 0, []byte(`{"continue":"bounded"}`)); err != nil {
		t.Fatal(err)
	}
	_, _, err := state.EnqueueSelfContinuationForThread(entry.WorkID, "thread", intro.Sequence, 0, []byte(`{"session_credential":"secret"}`))
	if !errors.Is(err, ErrClientActorPrivacyCanary) {
		t.Fatalf("duplicate sensitive continuation err=%v, want privacy", err)
	}
}

func TestClientActorPresentationAckRequiresPendingContiguousTuple(t *testing.T) {
	state := testClientActorState(t)
	first := settleCompletionWork(t, &state, "completion:1")
	second := settleCompletionWork(t, &state, "completion:2")
	if err := state.EmitPresentation(first.Sequence); err != nil {
		t.Fatal(err)
	}
	if err := state.EmitPresentation(second.Sequence); err != nil {
		t.Fatal(err)
	}
	if err := state.AckPresentation("client", state.CurrentFence, second.Sequence); !errors.Is(err, ErrClientActorPresentationAckRange) {
		t.Fatalf("out-of-order ack err=%v, want range", err)
	}
	wrong := state.CurrentFence
	wrong.ExecutorGeneration++
	if err := state.AckPresentation("client", wrong, first.Sequence); !errors.Is(err, ErrClientActorStaleFence) {
		t.Fatalf("stale tuple err=%v, want stale", err)
	}
	if err := state.AckPresentation("client", state.CurrentFence, first.Sequence); err != nil {
		t.Fatal(err)
	}
	if err := state.AckPresentation("client", state.CurrentFence, first.Sequence); !errors.Is(err, ErrClientActorPresentationAckRange) {
		t.Fatalf("stale duplicate ack err=%v, want range", err)
	}
	if err := state.AckPresentation("client", state.CurrentFence, second.Sequence); err != nil {
		t.Fatal(err)
	}
	if state.PresentationAckHigh != second.Sequence || len(state.PendingPresentation) != 0 {
		t.Fatalf("ack high/pending mismatch high=%d pending=%d", state.PresentationAckHigh, len(state.PendingPresentation))
	}
}

func TestClientOriginUnfencedLifecycleEventsRejected(t *testing.T) {
	state := testClientActorState(t)
	if _, err := state.ClientOriginAppendWork(ClientActorExecutorFence{}, ClientActorSemanticCompletion, "completion", []byte(`{}`)); !errors.Is(err, ErrClientActorInvalidBoundary) {
		t.Fatalf("client-origin lifecycle append err=%v, want invalid boundary", err)
	}
	if _, _, err := state.AdmitUserTurnForThread(ClientActorExecutorFence{}, "thread", "nonce", []byte(`{}`)); !errors.Is(err, ErrClientActorInvalidBoundary) {
		t.Fatalf("unfenced admission err=%v, want invalid boundary", err)
	}
	if _, _, err := state.ClientOriginEnqueueSelfContinuation(ClientActorExecutorFence{}, "turn", 1, 0, []byte(`{}`)); !errors.Is(err, ErrClientActorInvalidBoundary) {
		t.Fatalf("client-origin continuation err=%v, want invalid boundary", err)
	}
}

func TestClientActorWaitingBlockedCompletionIntrospectionHaveDistinctAppendRules(t *testing.T) {
	state := testClientActorState(t)
	families := []ClientActorSemanticFamily{ClientActorSemanticWaiting, ClientActorSemanticBlocked, ClientActorSemanticCompletion, ClientActorSemanticIntrospection}
	for i, family := range families {
		entry, err := state.AppendWork(family, string(rune('a'+i))+":work", []byte(`{"state":"bounded"}`))
		if err != nil {
			t.Fatalf("AppendWork(%s) err=%v", family, err)
		}
		if entry.Family != family || state.WorkFamilies[entry.WorkID] != family {
			t.Fatalf("family was not retained distinctly for %s: %#v", family, entry)
		}
		if err := state.AssignWorkToLease(entry.WorkID, state.CurrentFence); err != nil {
			t.Fatal(err)
		}
		if _, _, err := state.SettleWork(state.CurrentFence, entry.WorkID, ClientActorSemanticAsk, false, []byte(`{"state":"bounded"}`), ClientActorSettlementDigestFromJSON); !errors.Is(err, ErrClientActorDuplicateSemantic) {
			t.Fatalf("settle %s as ask err=%v, want non-interchangeable", family, err)
		}
	}
}

func TestClientActorPrivacyCanariesRejected(t *testing.T) {
	state := testClientActorState(t)
	canaries := [][]byte{
		[]byte(`{"raw_reasoning":"do not store"}`),
		[]byte("literal redacted marker"),
		[]byte("Authorization : bearer token"),
		[]byte("Bearer sk-token"),
		[]byte("OPENAI_API_KEY=sk-test"),
		[]byte("-----BEGIN PRIVATE KEY-----\nabc"),
		[]byte("/home/user/.ssh/id_rsa"),
		[]byte("session_credential"),
	}
	for i, canary := range canaries {
		if _, _, err := state.AdmitUserTurn(fmt.Sprintf("canary-%d", i), canary); !errors.Is(err, ErrClientActorPrivacyCanary) {
			t.Fatalf("privacy admission for %q err=%v, want canary rejection", canary, err)
		}
	}
	if _, err := state.AppendWork(ClientActorSemanticAsk, "ask:secret", []byte("Authorization: bearer token")); !errors.Is(err, ErrClientActorPrivacyCanary) {
		t.Fatalf("privacy append err=%v, want canary rejection", err)
	}
}

func TestClientActorSettlementSequenceIsDurableReplayLogEntry(t *testing.T) {
	state := testClientActorState(t)
	entry := admitAssignedTurn(t, &state, "nonce")
	settlement, committed, err := state.SettleWork(state.CurrentFence, entry.WorkID, entry.Family, true, []byte(`{"result":"ok"}`), ClientActorSettlementDigestFromJSON)
	if err != nil || !committed {
		t.Fatalf("settlement committed=%v err=%v", committed, err)
	}
	seen := map[uint64]bool{}
	for _, logEntry := range state.Log {
		if seen[logEntry.ReplaySequence] {
			t.Fatalf("duplicate replay sequence %d", logEntry.ReplaySequence)
		}
		seen[logEntry.ReplaySequence] = true
	}
	for seq := uint64(1); seq < state.NextReplaySequence; seq++ {
		if !seen[seq] {
			t.Fatalf("consumed replay sequence %d missing from durable replay log", seq)
		}
	}
	if replay, err := state.logEntry("settlement:" + entry.WorkID); err != nil || replay.EntryKind != ClientActorLogEntryKindSettlement || replay.Sequence != 0 || replay.ReplaySequence != settlement.SettlementSequence || replay.SourceWorkID != entry.WorkID {
		t.Fatalf("settlement replay entry mismatch replay=%#v err=%v settlement=%#v", replay, err, settlement)
	}
}

func TestClientActorSettlementHighWaterAdvancesContiguously(t *testing.T) {
	state := testClientActorState(t)
	first := admitAssignedTurn(t, &state, "first")
	second := admitAssignedTurn(t, &state, "second")
	settledSecond, _, err := state.SettleWork(state.CurrentFence, second.WorkID, second.Family, true, []byte(`{"result":"second"}`), ClientActorSettlementDigestFromJSON)
	if err != nil {
		t.Fatal(err)
	}
	if settledSecond.SettlementHigh != 0 || state.SettlementHighWater != 0 {
		t.Fatalf("out-of-order settlement advanced high-water: settlement=%#v global=%d", settledSecond, state.SettlementHighWater)
	}
	settledFirst, _, err := state.SettleWork(state.CurrentFence, first.WorkID, first.Family, true, []byte(`{"result":"first"}`), ClientActorSettlementDigestFromJSON)
	if err != nil {
		t.Fatal(err)
	}
	if settledFirst.SettlementHigh != second.Sequence || state.SettlementHighWater != second.Sequence {
		t.Fatalf("contiguous high-water did not catch up: first=%#v secondSeq=%d global=%d", settledFirst, second.Sequence, state.SettlementHighWater)
	}
}

func TestClientActorMarkIntrospectedRequiresDurableIntrospectionEntryAndSettlement(t *testing.T) {
	state := testClientActorState(t)
	source := admitAssignedTurn(t, &state, "source")
	if _, _, err := state.SettleWork(state.CurrentFence, source.WorkID, source.Family, false, []byte(`{"result":"future-action"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	if err := state.MarkIntrospected(source.WorkID, source.Sequence+1); !errors.Is(err, ErrClientActorContinuationSource) {
		t.Fatalf("no-introspection-entry err=%v, want source ineligible", err)
	}
	intro, err := state.AppendIntrospectionForSource(source.WorkID, "intro:unsettled", []byte(`{"decision":"continue"}`))
	if err != nil {
		t.Fatal(err)
	}
	if err := state.MarkIntrospected(source.WorkID, intro.Sequence); !errors.Is(err, ErrClientActorContinuationSource) {
		t.Fatalf("unsettled introspection err=%v, want source ineligible", err)
	}
	if err := state.AssignWorkToLease(intro.WorkID, state.CurrentFence); err != nil {
		t.Fatal(err)
	}
	if _, _, err := state.SettleWork(state.CurrentFence, intro.WorkID, intro.Family, true, []byte(`{"decision":"continue"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	if err := state.MarkIntrospected(source.WorkID, intro.Sequence); err != nil {
		t.Fatalf("settled introspection mark err=%v", err)
	}
}

func TestClientActorMarkIntrospectedRejectsWrongThreadIntrospection(t *testing.T) {
	state := testClientActorState(t)
	source := admitAssignedTurn(t, &state, "source")
	if _, _, err := state.SettleWork(state.CurrentFence, source.WorkID, source.Family, false, []byte(`{"result":"future-action"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	intro, err := state.AppendIntrospectionForThread(source.WorkID, "intro:wrong-thread", "other-thread", []byte(`{"decision":"continue"}`))
	if err != nil {
		t.Fatal(err)
	}
	if err := state.AssignWorkToLease(intro.WorkID, state.CurrentFence); err != nil {
		t.Fatal(err)
	}
	if _, _, err := state.SettleWork(state.CurrentFence, intro.WorkID, intro.Family, true, []byte(`{"decision":"continue"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	if err := state.MarkIntrospected(source.WorkID, intro.Sequence); !errors.Is(err, ErrClientActorContinuationSource) {
		t.Fatalf("wrong-thread introspection err=%v, want source ineligible", err)
	}
}

func TestClientActorAssignWorkToLeaseRejectsTerminalReassignment(t *testing.T) {
	state := testClientActorState(t)
	entry := admitAssignedTurn(t, &state, "nonce")
	if _, _, err := state.SettleWork(state.CurrentFence, entry.WorkID, entry.Family, true, []byte(`{"result":"ok"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	if err := state.AssignWorkToLease(entry.WorkID, state.CurrentFence); !errors.Is(err, ErrClientActorAlreadySettled) {
		t.Fatalf("terminal reassignment err=%v, want already settled", err)
	}
}

func TestClientActorContinuationRejectsTerminalSourceSettlement(t *testing.T) {
	state := testClientActorState(t)
	entry := admitAssignedTurn(t, &state, "terminal-source")
	if _, _, err := state.SettleWork(state.CurrentFence, entry.WorkID, entry.Family, true, []byte(`{"result":"done"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	intro := settleIntrospectionForSource(t, &state, entry, "intro:terminal-source")
	if err := state.MarkIntrospected(entry.WorkID, intro.Sequence); !errors.Is(err, ErrClientActorContinuationSource) {
		t.Fatalf("terminal source introspection err=%v, want continuation source rejection", err)
	}
	if _, _, err := state.EnqueueSelfContinuationForThread(entry.WorkID, "thread", intro.Sequence, 0, []byte(`{"continue":"bounded"}`)); !errors.Is(err, ErrClientActorContinuationSource) {
		t.Fatalf("terminal source continuation err=%v, want continuation source rejection", err)
	}
}

func TestClientActorPresentationAckRejectsWrongOrEmptyLeaseID(t *testing.T) {
	state := testClientActorState(t)
	entry := settleCompletionWork(t, &state, "presentation:lease")
	if err := state.EmitPresentation(entry.Sequence); err != nil {
		t.Fatal(err)
	}
	wrongLease := state.CurrentFence
	wrongLease.LeaseID = "other-lease"
	if err := state.AckPresentation("client", wrongLease, entry.Sequence); !errors.Is(err, ErrClientActorStaleFence) {
		t.Fatalf("wrong lease ack err=%v, want stale fence", err)
	}
	emptyLease := state.CurrentFence
	emptyLease.LeaseID = ""
	if err := state.AckPresentation("client", emptyLease, entry.Sequence); !errors.Is(err, ErrClientActorStaleFence) {
		t.Fatalf("empty lease ack err=%v, want stale fence", err)
	}
}

func TestClientActorAssignWorkToLeaseExactReplayAndConflict(t *testing.T) {
	state := testClientActorState(t)
	entry, _, err := state.AdmitUserTurnForThread(state.CurrentFence, "thread", "lease-replay", []byte(`{"input":"hello"}`))
	if err != nil {
		t.Fatal(err)
	}
	if err := state.AssignWorkToLease(entry.WorkID, state.CurrentFence); err != nil {
		t.Fatalf("initial assignment err=%v", err)
	}
	if err := state.AssignWorkToLease(entry.WorkID, state.CurrentFence); err != nil {
		t.Fatalf("exact replay assignment err=%v", err)
	}
	rotated := state.CurrentFence
	rotated.ExecutorGeneration++
	rotated.LeaseID = "rotated-lease"
	state.CurrentFence = rotated
	if err := state.AssignWorkToLease(entry.WorkID, rotated); !errors.Is(err, ErrClientActorLeaseConflict) {
		t.Fatalf("conflicting reassignment err=%v, want lease conflict", err)
	}
}

func TestClientActorDurableIdentifierPrivacyAndShapeValidation(t *testing.T) {
	validFence := ClientActorExecutorFence{ActorEpoch: 1, ExecutorGeneration: 1, LeaseID: "lease-safe"}
	invalidIDs := []string{
		"",
		strings.Repeat("a", 129),
		"with space",
		"with\ncontrol",
		"/home/user/thread",
		"path\\secret",
		"literal-redacted-id",
		"Bearer token",
		"OPENAI_API_KEY",
		"Authorization:token",
		"session_credential",
	}
	for _, id := range invalidIDs {
		if _, err := NewDurableClientActorContractState(id, validFence); !errors.Is(err, ErrClientActorInvalidIdentifier) {
			t.Fatalf("actor id %q err=%v, want invalid identifier", id, err)
		}
	}
	if _, err := NewDurableClientActorContractState("client", ClientActorExecutorFence{ActorEpoch: 1, ExecutorGeneration: 1, LeaseID: "Bearer token"}); !errors.Is(err, ErrClientActorInvalidBoundary) {
		t.Fatalf("lease id privacy err=%v, want invalid boundary", err)
	}
	state := testClientActorState(t)
	for _, id := range invalidIDs {
		if _, _, err := state.AdmitUserTurnForThread(state.CurrentFence, id, "nonce-shape", []byte(`{}`)); !errors.Is(err, ErrClientActorInvalidIdentifier) {
			t.Fatalf("thread id %q err=%v, want invalid identifier", id, err)
		}
		if _, _, err := state.AdmitUserTurnForThread(state.CurrentFence, "thread", id, []byte(`{}`)); !errors.Is(err, ErrClientActorInvalidIdentifier) {
			t.Fatalf("nonce %q err=%v, want invalid identifier", id, err)
		}
		if _, err := state.AppendWork(ClientActorSemanticAsk, id, []byte(`{}`)); !errors.Is(err, ErrClientActorInvalidIdentifier) {
			t.Fatalf("work id %q err=%v, want invalid identifier", id, err)
		}
	}
}

func TestClientActorSparsePresentationAcksUsePresentationOrder(t *testing.T) {
	state := testClientActorState(t)
	_ = settleCompletionWork(t, &state, "completion:not-presented")
	presented := settleCompletionWork(t, &state, "completion:presented")
	if presented.Sequence != 2 {
		t.Fatalf("test expected sparse raw log sequence 2, got %d", presented.Sequence)
	}
	if err := state.EmitPresentation(presented.Sequence); err != nil {
		t.Fatal(err)
	}
	if err := state.AckPresentation("client", state.CurrentFence, presented.Sequence); err != nil {
		t.Fatalf("sparse presentation ack should follow presentation order, not raw log sequence: %v", err)
	}
	if state.PresentationAckHigh != presented.Sequence || state.PresentationAckOrderHigh != 1 {
		t.Fatalf("unexpected sparse ack cursors high=%d order=%d", state.PresentationAckHigh, state.PresentationAckOrderHigh)
	}
}

func TestClientActorSettlementReplayEventsDoNotCreatePermanentWorkSequenceGaps(t *testing.T) {
	state := testClientActorState(t)
	first := admitAssignedTurn(t, &state, "gap-first")
	if _, _, err := state.SettleWork(state.CurrentFence, first.WorkID, first.Family, true, []byte(`{"result":"first"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	second := admitAssignedTurn(t, &state, "gap-second")
	third := admitAssignedTurn(t, &state, "gap-third")
	if second.Sequence != 2 || third.Sequence != 3 {
		t.Fatalf("settlement replay event polluted dense work sequence: second=%d third=%d", second.Sequence, third.Sequence)
	}
	if _, _, err := state.SettleWork(state.CurrentFence, third.WorkID, third.Family, true, []byte(`{"result":"third"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	if state.SettlementHighWater != 1 {
		t.Fatalf("high-water skipped unsettled second work: %d", state.SettlementHighWater)
	}
	settledSecond, _, err := state.SettleWork(state.CurrentFence, second.WorkID, second.Family, true, []byte(`{"result":"second"}`), ClientActorSettlementDigestFromJSON)
	if err != nil {
		t.Fatal(err)
	}
	if settledSecond.SettlementHigh != 3 || state.SettlementHighWater != 3 {
		t.Fatalf("high-water did not advance across dense work seq after replay entries: settlement=%#v high=%d", settledSecond, state.SettlementHighWater)
	}
}

func TestClientActorRebuildIndexesFromLogIgnoresSettlementReplayEntries(t *testing.T) {
	state := testClientActorState(t)
	first := admitAssignedTurn(t, &state, "rebuild-first")
	second := admitAssignedTurn(t, &state, "rebuild-second")
	if _, _, err := state.SettleWork(state.CurrentFence, first.WorkID, first.Family, true, []byte(`{"result":"first"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	log := append([]DurableClientActorLogEntry(nil), state.Log...)
	restored := DurableClientActorContractState{SchemaVersion: DurableClientActorContractSchemaV1, ActorID: state.ActorID, CurrentFence: state.CurrentFence, Log: log}
	if err := restored.RebuildIndexesFromLog(); err != nil {
		t.Fatalf("rebuild err=%v", err)
	}
	if restored.WorkBySequence[first.Sequence] != first.WorkID || restored.WorkBySequence[second.Sequence] != second.WorkID {
		t.Fatalf("work indexes not rebuilt: %#v", restored.WorkBySequence)
	}
	for seq, workID := range restored.WorkBySequence {
		if strings.HasPrefix(workID, "settlement:") {
			t.Fatalf("settlement replay entry indexed as work seq=%d work=%s", seq, workID)
		}
	}
	if restored.NextSequence != 3 || restored.NextReplaySequence != uint64(len(log)+1) {
		t.Fatalf("restored counters wrong: nextWork=%d nextReplay=%d log=%d", restored.NextSequence, restored.NextReplaySequence, len(log))
	}
	settlementReplay, err := restored.logEntry("settlement:" + first.WorkID)
	if err != nil || settlementReplay.EntryKind != ClientActorLogEntryKindSettlement || settlementReplay.SourceWorkID != first.WorkID || settlementReplay.Sequence != 0 {
		t.Fatalf("settlement replay invariant lost: %#v err=%v", settlementReplay, err)
	}
}

func TestClientActorMarkIntrospectedRejectsNonterminalIntrospectionSettlement(t *testing.T) {
	state := testClientActorState(t)
	source := admitAssignedTurn(t, &state, "nonterminal-introspection")
	if _, _, err := state.SettleWork(state.CurrentFence, source.WorkID, source.Family, false, []byte(`{"result":"future-action"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	intro, err := state.AppendIntrospectionForSource(source.WorkID, "intro:nonterminal", []byte(`{"decision":"continue"}`))
	if err != nil {
		t.Fatal(err)
	}
	if err := state.AssignWorkToLease(intro.WorkID, state.CurrentFence); err != nil {
		t.Fatal(err)
	}
	if _, _, err := state.SettleWork(state.CurrentFence, intro.WorkID, intro.Family, false, []byte(`{"decision":"continue"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	if err := state.MarkIntrospected(source.WorkID, intro.Sequence); !errors.Is(err, ErrClientActorContinuationSource) {
		t.Fatalf("nonterminal introspection err=%v, want continuation source rejection", err)
	}
}

func TestClientActorSettlementReplayWorkIDNamespaceIsReserved(t *testing.T) {
	state := testClientActorState(t)
	entry := admitAssignedTurn(t, &state, "reserved-settlement")
	if _, _, err := state.SettleWork(state.CurrentFence, entry.WorkID, entry.Family, true, []byte(`{"result":"ok"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	if _, err := state.AppendWork(ClientActorSemanticAsk, "settlement:"+entry.WorkID, []byte(`{"ask":"collision"}`)); !errors.Is(err, ErrClientActorInvalidIdentifier) {
		t.Fatalf("settlement namespace collision err=%v, want invalid identifier", err)
	}
}

func TestClientActorEmitPresentationRejectsIneligibleSources(t *testing.T) {
	state := testClientActorState(t)
	userTurn, _, err := state.AdmitUserTurn("presentation-user", []byte(`{"input":"hello"}`))
	if err != nil {
		t.Fatal(err)
	}
	if err := state.EmitPresentation(userTurn.Sequence); !errors.Is(err, ErrClientActorPresentationSource) {
		t.Fatalf("user turn presentation err=%v, want source rejection", err)
	}
	waiting, err := state.AppendWork(ClientActorSemanticWaiting, "waiting:presentation", []byte(`{"state":"waiting"}`))
	if err != nil {
		t.Fatal(err)
	}
	if err := state.AssignWorkToLease(waiting.WorkID, state.CurrentFence); err != nil {
		t.Fatal(err)
	}
	if _, _, err := state.SettleWork(state.CurrentFence, waiting.WorkID, waiting.Family, true, []byte(`{"state":"waiting"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	if err := state.EmitPresentation(waiting.Sequence); !errors.Is(err, ErrClientActorPresentationSource) {
		t.Fatalf("waiting presentation err=%v, want source rejection", err)
	}
	completion, err := state.AppendWork(ClientActorSemanticCompletion, "completion:unsettled-presentation", []byte(`{"summary":"done"}`))
	if err != nil {
		t.Fatal(err)
	}
	if err := state.EmitPresentation(completion.Sequence); !errors.Is(err, ErrClientActorPresentationSource) {
		t.Fatalf("unsettled completion presentation err=%v, want source rejection", err)
	}
}

func TestClientActorAppendIntrospectionValidatesSourceShapePrivacyAndExistence(t *testing.T) {
	state := testClientActorState(t)
	invalidSources := []string{"/home/user/source", "Bearer token", "OPENAI_API_KEY", "session_credential", "settlement:future"}
	for _, source := range invalidSources {
		if _, err := state.AppendIntrospectionForThread(source, "intro:"+fmt.Sprintf("%x", sha256.Sum256([]byte(source)))[:8], "thread", []byte(`{"decision":"continue"}`)); !errors.Is(err, ErrClientActorInvalidIdentifier) {
			t.Fatalf("source %q err=%v, want invalid identifier", source, err)
		}
	}
	if _, err := state.AppendIntrospectionForThread("missing-source", "intro:missing", "thread", []byte(`{"decision":"continue"}`)); !errors.Is(err, ErrClientActorContinuationSource) {
		t.Fatalf("nonexistent source err=%v, want source rejection", err)
	}
}

func TestClientActorSettlementReplayPreservesSettledSemanticFamily(t *testing.T) {
	state := testClientActorState(t)
	families := []ClientActorSemanticFamily{ClientActorSemanticWaiting, ClientActorSemanticBlocked, ClientActorSemanticIntrospection}
	for i, family := range families {
		workID := fmt.Sprintf("semantic-replay:%d", i)
		entry, err := state.AppendWork(family, workID, []byte(`{"state":"bounded"}`))
		if err != nil {
			t.Fatal(err)
		}
		if err := state.AssignWorkToLease(entry.WorkID, state.CurrentFence); err != nil {
			t.Fatal(err)
		}
		if _, _, err := state.SettleWork(state.CurrentFence, entry.WorkID, entry.Family, true, []byte(`{"state":"bounded"}`), ClientActorSettlementDigestFromJSON); err != nil {
			t.Fatal(err)
		}
		replay, err := state.logEntry("settlement:" + entry.WorkID)
		if err != nil {
			t.Fatal(err)
		}
		if replay.EntryKind != ClientActorLogEntryKindSettlement || replay.Family != family || replay.SourceWorkID != entry.WorkID {
			t.Fatalf("settlement replay collapsed semantics: replay=%#v family=%s", replay, family)
		}
	}
}

func TestClientActorRebuildRejectsBadNonce(t *testing.T) {
	state := testClientActorState(t)
	entry, _, err := state.AdmitUserTurn("nonce-good", []byte(`{"input":"hello"}`))
	if err != nil {
		t.Fatal(err)
	}
	badNonces := []string{"/home/user/nonce", "literal-redacted-nonce", "Bearer token", "OPENAI_API_KEY", strings.Repeat("n", 129), "with space"}
	for _, nonce := range badNonces {
		log := append([]DurableClientActorLogEntry(nil), state.Log...)
		log[0].Nonce = nonce
		restored := DurableClientActorContractState{SchemaVersion: DurableClientActorContractSchemaV1, ActorID: state.ActorID, CurrentFence: state.CurrentFence, Log: log}
		if err := restored.RebuildIndexesFromLog(); !errors.Is(err, ErrClientActorCorruptState) {
			t.Fatalf("bad nonce %q for %s err=%v, want corrupt", nonce, entry.WorkID, err)
		}
	}
}

func TestClientActorRebuildRejectsBadOrMissingSettlementSourceWorkID(t *testing.T) {
	state := testClientActorState(t)
	entry := admitAssignedTurn(t, &state, "rebuild-source")
	if _, _, err := state.SettleWork(state.CurrentFence, entry.WorkID, entry.Family, true, []byte(`{"result":"ok"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	badSources := []string{"/home/user/source", "literal-redacted-source", "Bearer token", "OPENAI_API_KEY", strings.Repeat("s", 129), "missing-source"}
	for _, source := range badSources {
		log := append([]DurableClientActorLogEntry(nil), state.Log...)
		log[len(log)-1].SourceWorkID = source
		restored := DurableClientActorContractState{SchemaVersion: DurableClientActorContractSchemaV1, ActorID: state.ActorID, CurrentFence: state.CurrentFence, Log: log}
		if err := restored.RebuildIndexesFromLog(); !errors.Is(err, ErrClientActorCorruptState) {
			t.Fatalf("bad settlement source %q err=%v, want corrupt", source, err)
		}
	}
}

func TestClientActorRebuildRejectsDuplicateWorkSequence(t *testing.T) {
	state := testClientActorState(t)
	first, _, err := state.AdmitUserTurn("first-seq", []byte(`{"input":"one"}`))
	if err != nil {
		t.Fatal(err)
	}
	second, _, err := state.AdmitUserTurn("second-seq", []byte(`{"input":"two"}`))
	if err != nil {
		t.Fatal(err)
	}
	log := append([]DurableClientActorLogEntry(nil), state.Log...)
	log[1].Sequence = first.Sequence
	restored := DurableClientActorContractState{SchemaVersion: DurableClientActorContractSchemaV1, ActorID: state.ActorID, CurrentFence: state.CurrentFence, Log: log}
	if err := restored.RebuildIndexesFromLog(); !errors.Is(err, ErrClientActorCorruptState) {
		t.Fatalf("duplicate sequence %d/%d err=%v, want corrupt", first.Sequence, second.Sequence, err)
	}
}

func TestClientActorRebuildRejectsDuplicateNonceDifferentWorkID(t *testing.T) {
	state := testClientActorState(t)
	first, _, err := state.AdmitUserTurn("restore-nonce", []byte(`{"input":"one"}`))
	if err != nil {
		t.Fatal(err)
	}
	duplicate := first
	duplicate.ReplaySequence = state.NextReplaySequence
	duplicate.Sequence = state.NextSequence
	duplicate.WorkID = "user-turn:client:duplicate"
	log := append(append([]DurableClientActorLogEntry(nil), state.Log...), duplicate)
	restored := DurableClientActorContractState{SchemaVersion: DurableClientActorContractSchemaV1, ActorID: state.ActorID, CurrentFence: state.CurrentFence, Log: log}
	if err := restored.RebuildIndexesFromLog(); !errors.Is(err, ErrClientActorCorruptState) {
		t.Fatalf("same nonce different workID err=%v, want corrupt", err)
	}
	if record := restored.UserTurnByNonce["restore-nonce"]; record.WorkID == duplicate.WorkID {
		t.Fatalf("conflicting nonce overwrote index: %#v", record)
	}
}

func TestClientActorRebuildRejectsDuplicateNonceSameWorkIDDifferentDigest(t *testing.T) {
	state := testClientActorState(t)
	first, _, err := state.AdmitUserTurn("restore-nonce", []byte(`{"input":"one"}`))
	if err != nil {
		t.Fatal(err)
	}
	duplicate := first
	duplicate.ReplaySequence = state.NextReplaySequence
	duplicate.Content.Digest = sha256.Sum256([]byte(`{"input":"different"}`))
	log := append(append([]DurableClientActorLogEntry(nil), state.Log...), duplicate)
	restored := DurableClientActorContractState{SchemaVersion: DurableClientActorContractSchemaV1, ActorID: state.ActorID, CurrentFence: state.CurrentFence, Log: log}
	if err := restored.RebuildIndexesFromLog(); !errors.Is(err, ErrClientActorCorruptState) {
		t.Fatalf("same nonce/workID different digest err=%v, want corrupt", err)
	}
	if record := restored.UserTurnByNonce["restore-nonce"]; record.Digest == duplicate.Content.Digest {
		t.Fatalf("conflicting nonce digest overwrote index: %#v", record)
	}
}

func TestClientActorRebuildAllowsExactDuplicateNonceReplay(t *testing.T) {
	state := testClientActorState(t)
	first, _, err := state.AdmitUserTurn("restore-nonce", []byte(`{"input":"one"}`))
	if err != nil {
		t.Fatal(err)
	}
	duplicate := first
	duplicate.ReplaySequence = state.NextReplaySequence
	log := append(append([]DurableClientActorLogEntry(nil), state.Log...), duplicate)
	restored := DurableClientActorContractState{SchemaVersion: DurableClientActorContractSchemaV1, ActorID: state.ActorID, CurrentFence: state.CurrentFence, Log: log}
	if err := restored.RebuildIndexesFromLog(); err != nil {
		t.Fatalf("exact duplicate replay err=%v", err)
	}
	if record := restored.UserTurnByNonce["restore-nonce"]; record.WorkID != first.WorkID || record.Digest != first.Content.Digest {
		t.Fatalf("exact duplicate replay changed nonce index: %#v first=%#v", record, first)
	}
	if restored.WorkBySequence[first.Sequence] != first.WorkID || restored.NextSequence != first.Sequence+1 {
		t.Fatalf("exact duplicate replay changed work index/cursor: index=%#v next=%d", restored.WorkBySequence, restored.NextSequence)
	}
}

func TestClientActorRebuildRejectsBadSettlementReplayWorkID(t *testing.T) {
	state := testClientActorState(t)
	entry := admitAssignedTurn(t, &state, "bad-replay-work-id")
	if _, _, err := state.SettleWork(state.CurrentFence, entry.WorkID, entry.Family, true, []byte(`{"result":"ok"}`), ClientActorSettlementDigestFromJSON); err != nil {
		t.Fatal(err)
	}
	badIDs := []string{
		"/home/user/settlement",
		"settlement:/home/user/source",
		"settlement:literal-redacted-source",
		"settlement:Bearer token",
		"settlement:OPENAI_API_KEY",
		"not-settlement:" + entry.WorkID,
		"settlement:other-work",
	}
	for _, id := range badIDs {
		log := append([]DurableClientActorLogEntry(nil), state.Log...)
		log[len(log)-1].WorkID = id
		restored := DurableClientActorContractState{SchemaVersion: DurableClientActorContractSchemaV1, ActorID: state.ActorID, CurrentFence: state.CurrentFence, Log: log}
		if err := restored.RebuildIndexesFromLog(); !errors.Is(err, ErrClientActorCorruptState) {
			t.Fatalf("bad settlement replay work id %q err=%v, want corrupt", id, err)
		}
	}
}

func TestClientActorRebuildRejectsNonceOnNonUserTurnEntry(t *testing.T) {
	state := testClientActorState(t)
	entry, err := state.AppendWork(ClientActorSemanticAsk, "ask:nonce-forbidden", []byte(`{"ask":"work"}`))
	if err != nil {
		t.Fatal(err)
	}
	log := append([]DurableClientActorLogEntry(nil), state.Log...)
	log[0].Nonce = "nonce-on-ask"
	restored := DurableClientActorContractState{SchemaVersion: DurableClientActorContractSchemaV1, ActorID: state.ActorID, CurrentFence: state.CurrentFence, Log: log}
	if err := restored.RebuildIndexesFromLog(); !errors.Is(err, ErrClientActorCorruptState) {
		t.Fatalf("nonce-bearing non-user-turn %s err=%v, want corrupt", entry.WorkID, err)
	}
	if _, ok := restored.UserTurnByNonce["nonce-on-ask"]; ok {
		t.Fatalf("non-user-turn nonce was indexed: %#v", restored.UserTurnByNonce)
	}
}
