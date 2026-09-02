package actors

import (
	"bytes"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

func TestThreadAckCommitsWorkerResultWithoutCompletingTask(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	delivery := application.BridgeDelivery{Sequence: 7, SchedulerEpoch: 3, ActiveLease: 4, ThreadTurn: 1, ThreadID: "thread", DedupeID: "dedupe", CompletionKey: "completion", SourceScope: "scope", Kind: application.BridgeDeliveryPrompt}
	thread := application.DurableAgentThread{SchemaVersion: application.DurableAgentThreadSchemaV1, ThreadID: "thread", State: application.AgentThreadAwaitingAgentSettled, Turn: 1, ActiveDeliverySequence: 7, CompletionKey: "completion", PendingPrompt: []byte("prompt")}
	a := &AgentActor{id: "agent", threads: map[string]application.DurableAgentThread{"thread": thread}, threadOrder: []string{"thread"}, threadScheduler: application.DurableThreadScheduler{SchemaVersion: application.DurableThreadSchedulerSchemaV1, AgentID: "agent", ActiveThreadID: "thread", Epoch: 3, ActiveLease: 4}, bridgeDeliveries: []application.BridgeDelivery{delivery}, deliverySources: map[uint64]string{7: "key"}, committedAcks: map[uint64]application.DurableBridgeAckRecord{}, threadClock: func() time.Time { return now }}
	ack := &application.BridgeDeliveryAck{Sequence: 7, DedupeID: "dedupe", ThreadID: "thread", SchedulerEpoch: 3, ActiveLease: 4, ThreadTurn: 1, BridgeRunCounter: 5, AgentEndObserved: true, AgentSettledObserved: true, Delivered: true}
	result := application.BridgeIntentResult{Accepted: true, Completed: true, Result: []byte("worker answer")}
	if !a.commitThreadAck(ack, delivery, 0, result) {
		t.Fatal("exact settled acknowledgement was rejected")
	}
	settled := a.threads["thread"]
	if settled.State != application.AgentThreadSettled || !bytes.Equal(settled.WorkerResult, result.Result) || len(settled.PendingPrompt) != 0 || len(a.bridgeDeliveries) != 0 || a.threadScheduler.ActiveThreadID != "thread" {
		t.Fatalf("settlement was not retained for introspection: %#v", settled)
	}
	if a.ackCursor != 7 || a.bridgeRunCounterHighWater != 5 || len(a.committedAcks) != 1 {
		t.Fatalf("ack transport state did not commit atomically: cursor=%d run=%d records=%d", a.ackCursor, a.bridgeRunCounterHighWater, len(a.committedAcks))
	}
}

func TestFailedThreadDeliveryBecomesResumable(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	delivery := application.BridgeDelivery{Sequence: 7, SchedulerEpoch: 3, ActiveLease: 4, ThreadTurn: 1, ThreadID: "thread", DedupeID: "dedupe", CompletionKey: "completion", SourceScope: "scope", Kind: application.BridgeDeliveryPrompt}
	thread := application.DurableAgentThread{SchemaVersion: application.DurableAgentThreadSchemaV1, ThreadID: "thread", State: application.AgentThreadAwaitingAgentSettled, Turn: 1, ActiveDeliverySequence: 7, CompletionKey: "completion", PendingPrompt: []byte("prompt")}
	a := &AgentActor{id: "agent", threads: map[string]application.DurableAgentThread{"thread": thread}, threadScheduler: application.DurableThreadScheduler{SchemaVersion: application.DurableThreadSchedulerSchemaV1, AgentID: "agent", ActiveThreadID: "thread", Epoch: 3, ActiveLease: 4}, bridgeDeliveries: []application.BridgeDelivery{delivery}, deliverySources: map[uint64]string{7: "key"}, committedAcks: map[uint64]application.DurableBridgeAckRecord{}, threadClock: func() time.Time { return now }}
	ack := &application.BridgeDeliveryAck{Sequence: 7, DedupeID: "dedupe", ThreadID: "thread", SchedulerEpoch: 3, ActiveLease: 4, ThreadTurn: 1, BridgeRunCounter: 5, Delivered: false, Reason: "delivery failed"}
	if !a.commitThreadAck(ack, delivery, 0, application.BridgeIntentResult{Accepted: true, Reason: ack.Reason}) {
		t.Fatal("failed delivery evidence was rejected")
	}
	resumable := a.threads["thread"]
	if resumable.State != application.AgentThreadResumable || a.threadScheduler.ActiveThreadID != "" || len(a.threadScheduler.Resumable) != 1 || !resumable.NextAttempt.Equal(now.Add(time.Second)) {
		t.Fatalf("failed delivery was not durably resumable: %#v %#v", resumable, a.threadScheduler)
	}
}
