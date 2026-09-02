//go:build linux || darwin

package state

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

func TestStoreRejectsMismatchedDurableThreadAcknowledgement(t *testing.T) {
	root := t.TempDir()
	_ = os.Chmod(filepath.Dir(root), 0o700)
	_ = os.Chmod(root, 0o700)
	store, err := New(filepath.Join(root, "state"))
	if err != nil {
		t.Fatal(err)
	}
	record := testRecord(root)
	sessionID, generationID, principal := "session", "generation", "hosted:agent"
	key := fmt.Sprintf("%d:%s%d:%s%d:%s:%d:%d", len(sessionID), sessionID, len(generationID), generationID, len(principal), principal, 1, 1)
	record.AgentState.MutationScopes = []application.DurableMutationScope{{Key: key, SessionID: sessionID, GenerationID: generationID, Principal: principal, Fence: 1, Incarnation: 1}}
	record.AgentState.BridgeDeliveries = []application.BridgeDelivery{{Sequence: 1, DedupeID: "dedupe", SourceScope: "scope", CompletionKey: "completion", ThreadID: "thread", SchedulerEpoch: 2, ActiveLease: 3, ThreadTurn: 4}}
	record.AgentState.DeliverySources = map[uint64]string{1: key}
	record.AgentState.AckGapBuffer = []application.DurableBridgeAckRecord{{Sequence: 1, DedupeID: "dedupe", ThreadID: "thread", SchedulerEpoch: 2, ActiveLease: 3, ThreadTurn: 4, BridgeRunCounter: 5, AgentEndObserved: true, AgentSettledObserved: true, Delivered: true}}
	if err := store.Save(context.Background(), record); err != nil {
		t.Fatalf("exact durable thread acknowledgement rejected: %v", err)
	}
	record.AgentState.AckGapBuffer[0].ActiveLease++
	if err := store.Save(context.Background(), record); err == nil {
		t.Fatal("mismatched durable thread acknowledgement was accepted")
	}
}
