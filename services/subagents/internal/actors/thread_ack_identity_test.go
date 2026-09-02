package actors

import (
	"testing"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

func TestThreadAckIdentityRequiresExactSettlementTuple(t *testing.T) {
	agent := &AgentActor{hostedPiRuntime: application.HostedPiRuntimeBinding{RuntimeID: "runtime", Incarnation: 2}, bridgePiSession: "pi"}
	delivery := application.BridgeDelivery{Sequence: 7, DedupeID: "dedupe", Kind: application.BridgeDeliveryPrompt, SourceScope: "scope", CompletionKey: "completion", ThreadID: "thread", SchedulerEpoch: 3, ActiveLease: 4, ThreadTurn: 5}
	exact := &application.BridgeDeliveryAck{Sequence: 7, DedupeID: "dedupe", Kind: "prompt", SourceScope: "scope", CompletionKey: "completion", RuntimeID: "runtime", Incarnation: 2, PiSessionID: "pi", Delivered: true, ThreadID: "thread", SchedulerEpoch: 3, ActiveLease: 4, ThreadTurn: 5, BridgeRunCounter: 6, AgentEndObserved: true, AgentSettledObserved: true}
	if !agent.validAckIdentity(exact, &delivery) {
		t.Fatal("exact thread settlement tuple was rejected")
	}
	tests := map[string]func(*application.BridgeDeliveryAck){
		"thread":            func(value *application.BridgeDeliveryAck) { value.ThreadID = "other" },
		"epoch":             func(value *application.BridgeDeliveryAck) { value.SchedulerEpoch++ },
		"lease":             func(value *application.BridgeDeliveryAck) { value.ActiveLease++ },
		"turn":              func(value *application.BridgeDeliveryAck) { value.ThreadTurn++ },
		"run counter":       func(value *application.BridgeDeliveryAck) { value.BridgeRunCounter = 0 },
		"agent end":         func(value *application.BridgeDeliveryAck) { value.AgentEndObserved = false },
		"agent settled":     func(value *application.BridgeDeliveryAck) { value.AgentSettledObserved = false },
		"delivery sequence": func(value *application.BridgeDeliveryAck) { value.Sequence++ },
	}
	for name, mutate := range tests {
		t.Run(name, func(t *testing.T) {
			changed := *exact
			mutate(&changed)
			if agent.validAckIdentity(&changed, &delivery) {
				t.Fatal("mismatched thread settlement tuple was accepted")
			}
		})
	}
	agent.bridgeRunCounterHighWater = exact.BridgeRunCounter
	if agent.validAckIdentity(exact, &delivery) {
		t.Fatal("stale bridge run counter was accepted")
	}
}

func TestThreadAckDuplicateFingerprintIncludesSettlementEvidence(t *testing.T) {
	exact := &application.BridgeDeliveryAck{Sequence: 7, DedupeID: "dedupe", Kind: "prompt", SourceScope: "scope", CompletionKey: "completion", RuntimeID: "runtime", Incarnation: 2, PiSessionID: "pi", Delivered: true, ThreadID: "thread", SchedulerEpoch: 3, ActiveLease: 4, ThreadTurn: 5, BridgeRunCounter: 6, AgentEndObserved: true, AgentSettledObserved: true}
	record := application.DurableBridgeAckRecord{Sequence: 7, DedupeID: "dedupe", Kind: application.BridgeDeliveryPrompt, SourceScope: "scope", CompletionKey: "completion", RuntimeID: "runtime", Incarnation: 2, PiSessionID: "pi", Delivered: true, ThreadID: "thread", SchedulerEpoch: 3, ActiveLease: 4, ThreadTurn: 5, BridgeRunCounter: 6, AgentEndObserved: true, AgentSettledObserved: true}
	if !bridgeAckMatchesRecord(exact, record) || !bridgeAcksMatch(exact, exact) {
		t.Fatal("exact duplicate settlement fingerprint did not match")
	}
	changed := *exact
	changed.BridgeRunCounter++
	if bridgeAckMatchesRecord(&changed, record) || bridgeAcksMatch(&changed, exact) {
		t.Fatal("changed settlement evidence matched retained duplicate")
	}
}
