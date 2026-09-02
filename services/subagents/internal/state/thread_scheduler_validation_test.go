//go:build linux || darwin

package state

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

func TestStoreValidatesThreadSchedulerReferencesAndBounds(t *testing.T) {
	root := t.TempDir()
	_ = os.Chmod(filepath.Dir(root), 0o700)
	_ = os.Chmod(root, 0o700)
	store, err := New(filepath.Join(root, "state"))
	if err != nil {
		t.Fatal(err)
	}
	record := testRecord(root)
	deadline := time.Unix(2_000_000_000, 0)
	intent := &application.BridgeIntent{SourceAgentID: "source", RequestID: "request", DedupeID: "dedupe", ChainID: "chain", SourceMutationSequence: 1, RequiredCapability: "ask", Deadline: deadline, HopLimit: 8, Mode: application.BridgeMessageAsk, Payload: []byte("prompt")}
	fingerprint := application.NewAgentThreadFingerprint(record.AgentID, intent)
	thread := application.DurableAgentThread{SchemaVersion: application.DurableAgentThreadSchemaV1, ThreadID: fingerprint.ThreadID(), Source: application.CommunicationPeer{StableID: "source"}, Target: application.CommunicationPeer{StableID: record.AgentID}, RequestID: intent.RequestID, DedupeID: intent.DedupeID, ChainID: intent.ChainID, SourceMutationSequence: intent.SourceMutationSequence, PayloadDigest: fingerprint.PayloadDigest, Mode: intent.Mode, RequiredCapability: intent.RequiredCapability, SourceScope: "scope", DeliverySourceKey: "source-key", DeliveryBackend: "hosted", TaskPrompt: append([]byte(nil), intent.Payload...), PendingPrompt: append([]byte(nil), intent.Payload...), Deadline: deadline, HopLimit: intent.HopLimit, State: application.AgentThreadQueued, ActiveDeliverySequence: 1, CompletionKey: "completion"}
	record.AgentState.Threads = []application.DurableAgentThread{thread}
	record.AgentState.ThreadScheduler = application.DurableThreadScheduler{SchemaVersion: application.DurableThreadSchedulerSchemaV1, AgentID: record.AgentID, Queue: []string{thread.ThreadID}}
	if err := store.Save(context.Background(), record); err != nil {
		t.Fatalf("valid queued scheduler rejected: %v", err)
	}
	record.AgentState.ThreadScheduler.Blocked = []string{thread.ThreadID}
	if err := store.Save(context.Background(), record); err == nil {
		t.Fatal("thread present in two scheduler sets was accepted")
	}
	for name, state := range map[string]application.AgentThreadState{"waiting": application.AgentThreadWaiting, "blocked": application.AgentThreadBlocked} {
		t.Run(name, func(t *testing.T) {
			candidate := record
			candidate.AgentState.Threads = append([]application.DurableAgentThread(nil), record.AgentState.Threads...)
			candidate.AgentState.Threads[0].State = state
			candidate.AgentState.ThreadScheduler.Queue = nil
			candidate.AgentState.ThreadScheduler.Blocked = nil
			if state == application.AgentThreadWaiting {
				candidate.AgentState.ThreadScheduler.Waiting = []string{thread.ThreadID}
			} else {
				candidate.AgentState.ThreadScheduler.Waiting = nil
				candidate.AgentState.ThreadScheduler.Blocked = []string{thread.ThreadID}
			}
			if err := store.Save(context.Background(), candidate); err != nil {
				t.Fatalf("valid %s thread rejected: %v", name, err)
			}
		})
	}
	tombstoned := record
	tombstoned.AgentState.Threads = nil
	tombstoned.AgentState.ThreadScheduler.Queue = nil
	tombstoned.AgentState.ThreadScheduler.Blocked = nil
	tombstoned.AgentState.ThreadScheduler.Tombstones = []application.DurableThreadTombstone{{ThreadID: thread.ThreadID, State: application.AgentThreadCompleted, CompletionKey: thread.CompletionKey}}
	if err := store.Save(context.Background(), tombstoned); err != nil {
		t.Fatalf("valid terminal tombstone rejected: %v", err)
	}
}
