package actors_test

import (
	"context"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
)

// restoredRecordingSource restores a source agent from durable state carrying
// the given outbox items and records every persisted record so tests can audit
// the durable outbox contents (credit retention, state label) across ticks.
func restoredRecordingSource(t *testing.T, ctx context.Context, system goakt.ActorSystem, name string, store *recordingStore, items ...application.DurableActorTaskOutboxItem) *goakt.PID {
	t.Helper()
	writer, err := system.Spawn(ctx, name+"-writer", &actors.HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	binding := application.InactiveHostedPiRuntimeBinding()
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "client:pm", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "client:pm"}, Binding: binding, AgentState: application.DurableAgentState{SourceOutbox: items}}
	pid, err := system.Spawn(ctx, name, actors.NewAgentActor(&application.RegisterAgent{AgentID: "client:pm", AuthorityBinding: record.AuthorityBinding, HostedPiRuntime: binding, AllowedCapability: []string{"send"}, Retention: "bounded", Recovery: "terminal-reattach", PersistencePID: writer, DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	return pid
}

// waitForOutboxRecord blocks until any persisted record's source outbox holds
// an item for the task whose state satisfies the predicate.
func waitForOutboxRecord(t *testing.T, store *recordingStore, taskID string, timeout time.Duration, accept func(application.DurableActorTaskOutboxItem) bool) application.DurableActorTaskOutboxItem {
	t.Helper()
	deadline := time.After(timeout)
	for {
		for _, record := range store.all() {
			for _, item := range record.AgentState.SourceOutbox {
				if item.TaskID == taskID && accept(item) {
					return item
				}
			}
		}
		select {
		case <-store.notify:
		case <-deadline:
			t.Fatalf("durable outbox never satisfied the awaited state for %s", taskID)
			return application.DurableActorTaskOutboxItem{}
		}
	}
}

// waitForCreditRequestCount blocks until the probe has observed at least
// `count` distinct credit requests, returning the newest one. Matching is by
// arrival count, not by re-reading the first buffered request.
func waitForCreditRequestCount(t *testing.T, probe *taskPeerProbe, count int, timeout time.Duration) (*application.RequestTaskCredit, bool) {
	t.Helper()
	deadline := time.After(timeout)
	for {
		probe.mu.Lock()
		seen, newest := 0, (*application.RequestTaskCredit)(nil)
		for _, message := range probe.received {
			if request, ok := message.(*application.RequestTaskCredit); ok {
				seen++
				newest = request
			}
		}
		probe.mu.Unlock()
		if seen >= count && newest != nil {
			return newest, true
		}
		select {
		case <-probe.notify:
		case <-deadline:
			return nil, false
		}
	}
}

// TestExpiredOutboxCreditIsDiscardedAndReRequested pins the TASK-12c live
// failure signature: an item restored from durable state with a held credit
// whose lease already expired (state label still "sent") must not carry the
// dead credit forever. The retry tick discards the expired credit, returns the
// item to pending_credit durably, and re-requests credit from the target, so
// grant -> send -> accept completes for the previously latched item.
func TestExpiredOutboxCreditIsDiscardedAndReRequested(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("outbox-expired-credit", goakt.WithPubSub())
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
	committed := make(chan *application.TargetTaskCommitted, 4)
	if _, err = system.Spawn(ctx, "expired-credit-commit-probe", &committedTopicProbe{committed: committed}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-committed:
	case <-time.After(time.Second):
		t.Fatal("TargetTaskCommitted subscription not acknowledged")
	}
	target := spawnTaskPeer(t, ctx, system, "expired-credit-target")
	payload := []byte("expired credit payload")
	digest := sha256Sum(payload)
	// The live stuck state exactly: a held credit whose lease expired minutes
	// ago while the state label still reads "sent" from the broken window.
	item := application.DurableActorTaskOutboxItem{TaskID: "client:pm:expired:chain:1", Target: application.CommunicationPeer{StableID: "target-agent"}, TargetRef: actorRefOf("target-agent", target.pid), RequestID: "request-expired", DedupeID: "expired", ChainID: "chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 4, Mode: application.BridgeMessageTell, Payload: payload, PayloadDigest: digest, Credit: application.TaskCredit{TaskID: "client:pm:expired:chain:1", CreditID: "credit-stale", TargetEpoch: 9, ExpiresAt: time.Now().Add(-17 * time.Minute), PayloadDigest: digest}, State: "sent"}
	store := &recordingStore{notify: make(chan struct{}, 16)}
	source := restoredRecordingSource(t, ctx, system, "expired-credit-source", store, item)
	// The expired credit must be discarded durably: no credit id and the
	// pending_credit label, persisted by the very tick that noticed expiry.
	discarded := waitForOutboxRecord(t, store, item.TaskID, 2*time.Second, func(persisted application.DurableActorTaskOutboxItem) bool {
		return persisted.Credit.CreditID == "" && persisted.State == "pending_credit"
	})
	if discarded.Attempts == 0 {
		t.Fatalf("expired-credit discard record lost the attempt history: %#v", discarded)
	}
	// The same tick re-requests: a fresh credit request must reach the target.
	request, ok := target.waitForCreditRequest(2 * time.Second)
	if !ok {
		t.Fatal("item holding an expired credit never re-requested credit")
	}
	if request.TaskID != item.TaskID {
		t.Fatalf("re-request carried the wrong task: %#v", request)
	}
	// grant -> send -> accept must complete for the previously latched item.
	if err = target.tell(ctx, source, &application.TaskCreditGranted{Credit: application.TaskCredit{TaskID: item.TaskID, CreditID: "credit-fresh", TargetEpoch: 10, ExpiresAt: time.Now().Add(30 * time.Second), PayloadDigest: request.PayloadDigest}}); err != nil {
		t.Fatal(err)
	}
	task, ok := target.waitFor("task", 2*time.Second).(*application.ActorTask)
	if !ok {
		t.Fatal("fresh grant for the previously latched item never produced the actor task send")
	}
	if task.Credit.CreditID != "credit-fresh" || string(task.Payload) != string(payload) {
		t.Fatalf("redrive sent the wrong credit or payload: %#v", task.Credit)
	}
	if err = target.tell(ctx, source, &application.ActorTaskAccepted{TaskID: item.TaskID, CreditID: "credit-fresh", TargetAgentID: "target-agent", Accepted: true}); err != nil {
		t.Fatal(err)
	}
	select {
	case message := <-committed:
		if message == nil || message.TaskID != item.TaskID {
			t.Fatalf("expired-credit recovery published the wrong commit: %#v", message)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("expired-credit recovery never published its commit")
	}
}

// TestExpiredGrantClearsAwaitedLatch pins the single-flight half of TASK-12c:
// a grant that arrives already expired must clear the awaited latch so the
// next bounded tick re-requests immediately instead of staying suppressed for
// the remainder of the request window.
func TestExpiredGrantClearsAwaitedLatch(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("outbox-expired-grant", goakt.WithPubSub())
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
	committed := make(chan *application.TargetTaskCommitted, 4)
	if _, err = system.Spawn(ctx, "expired-grant-commit-probe", &committedTopicProbe{committed: committed}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-committed:
	case <-time.After(time.Second):
		t.Fatal("TargetTaskCommitted subscription not acknowledged")
	}
	target := spawnTaskPeer(t, ctx, system, "expired-grant-target")
	payload := []byte("expired grant payload")
	digest := sha256Sum(payload)
	item := application.DurableActorTaskOutboxItem{TaskID: "client:pm:expgrant:chain:1", Target: application.CommunicationPeer{StableID: "target-agent"}, TargetRef: actorRefOf("target-agent", target.pid), RequestID: "request-expgrant", DedupeID: "expgrant", ChainID: "chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 4, Mode: application.BridgeMessageTell, Payload: payload, PayloadDigest: digest, State: "pending_credit"}
	store := &recordingStore{notify: make(chan struct{}, 16)}
	source := restoredRecordingSource(t, ctx, system, "expired-grant-source", store, item)
	// First request leaves the single-flight latch set and unanswered.
	request, ok := target.waitForCreditRequest(2 * time.Second)
	if !ok {
		t.Fatal("restored item never requested credit")
	}
	// A grant whose lease already elapsed arrives while the latch is fresh:
	// it must clear the latch so the next tick (~50ms) re-requests, well
	// inside the 500ms single-flight window that would otherwise suppress it.
	if err = target.tell(ctx, source, &application.TaskCreditGranted{Credit: application.TaskCredit{TaskID: item.TaskID, CreditID: "credit-dead", TargetEpoch: 3, ExpiresAt: time.Now().Add(-time.Second), PayloadDigest: request.PayloadDigest}}); err != nil {
		t.Fatal(err)
	}
	second, ok := waitForCreditRequestCount(t, target, 2, 400*time.Millisecond)
	if !ok {
		t.Fatal("expired grant left the single-flight latch set: no second request inside the window")
	}
	if second.TaskID != item.TaskID {
		t.Fatalf("re-request carried the wrong task: %#v", second)
	}
	// The recovered request completes grant -> send -> accept.
	if err = target.tell(ctx, source, &application.TaskCreditGranted{Credit: application.TaskCredit{TaskID: item.TaskID, CreditID: "credit-live", TargetEpoch: 4, ExpiresAt: time.Now().Add(30 * time.Second), PayloadDigest: second.PayloadDigest}}); err != nil {
		t.Fatal(err)
	}
	if _, ok = target.waitFor("task", 2*time.Second).(*application.ActorTask); !ok {
		t.Fatal("recovered request never produced the actor task send")
	}
	if err = target.tell(ctx, source, &application.ActorTaskAccepted{TaskID: item.TaskID, CreditID: "credit-live", TargetAgentID: "target-agent", Accepted: true}); err != nil {
		t.Fatal(err)
	}
	select {
	case message := <-committed:
		if message == nil || message.TaskID != item.TaskID {
			t.Fatalf("expired-grant recovery published the wrong commit: %#v", message)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("expired-grant recovery never published its commit")
	}
}
