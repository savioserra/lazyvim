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

func (p *taskPeerProbe) creditRequestCount() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	total := 0
	for _, message := range p.received {
		if _, ok := message.(*application.RequestTaskCredit); ok {
			total++
		}
	}
	return total
}

func (p *taskPeerProbe) waitForCreditRequest(timeout time.Duration) (*application.RequestTaskCredit, bool) {
	deadline := time.After(timeout)
	for {
		p.mu.Lock()
		for _, message := range p.received {
			if request, ok := message.(*application.RequestTaskCredit); ok {
				p.mu.Unlock()
				return request, true
			}
		}
		p.mu.Unlock()
		select {
		case <-p.notify:
		case <-deadline:
			return nil, false
		}
	}
}

// recordingStore records every persisted target record so tests can audit the
// credit epoch and reservation history of a real target agent.
type recordingStore struct {
	mu      sync.Mutex
	records []application.DurableHostedRecord
	notify  chan struct{}
}

func (s *recordingStore) Save(_ context.Context, r application.DurableHostedRecord) error {
	s.mu.Lock()
	s.records = append(s.records, r)
	s.mu.Unlock()
	select {
	case s.notify <- struct{}{}:
	default:
	}
	return nil
}
func (*recordingStore) Remove(context.Context, string) error { return nil }

// slowSaveStore delays every persist before recording it, so credit grants
// and task acceptances span several outbox retry ticks.
type slowSaveStore struct {
	mu      sync.Mutex
	records []application.DurableHostedRecord
	notify  chan struct{}
	delay   time.Duration
}

func (s *slowSaveStore) Save(_ context.Context, r application.DurableHostedRecord) error {
	time.Sleep(s.delay)
	s.mu.Lock()
	s.records = append(s.records, r)
	s.mu.Unlock()
	select {
	case s.notify <- struct{}{}:
	default:
	}
	return nil
}
func (*slowSaveStore) Remove(context.Context, string) error { return nil }

func (s *slowSaveStore) all() []application.DurableHostedRecord {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]application.DurableHostedRecord(nil), s.records...)
}

func (s *recordingStore) all() []application.DurableHostedRecord {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]application.DurableHostedRecord(nil), s.records...)
}

// waitForReservation blocks until any persisted record carries a task credit
// reservation for the task.
func (s *recordingStore) waitForReservation(t *testing.T, taskID string, timeout time.Duration) application.DurableHostedRecord {
	t.Helper()
	deadline := time.After(timeout)
	for {
		for _, record := range s.all() {
			for _, reservation := range record.AgentState.TaskCreditReservations {
				if reservation.Credit.TaskID == taskID {
					return record
				}
			}
		}
		select {
		case <-s.notify:
		case <-deadline:
			t.Fatalf("target never persisted a credit reservation for %s", taskID)
			return application.DurableHostedRecord{}
		}
	}
}

func countProbeMessages(p *taskPeerProbe, match func(any) bool) int {
	p.mu.Lock()
	defer p.mu.Unlock()
	total := 0
	for _, message := range p.received {
		if match(message) {
			total++
		}
	}
	return total
}

func restoredOutboxSource(t *testing.T, ctx context.Context, system goakt.ActorSystem, name string, items ...application.DurableActorTaskOutboxItem) *goakt.PID {
	t.Helper()
	store := &cursorAckStore{notify: make(chan struct{}, 8)}
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

// TestOutboxHeldUnexpiredCreditIsSentNotReRequested pins PM fix 1: an outbox
// item that already holds an unexpired, unconsumed credit must spend it, even
// when its state label was reset to pending_credit by a stale backpressure
// reply. Re-requesting instead rotates the target credit epoch, so every task
// Tell then carries a stale-epoch credit and is silently rejected.
func TestOutboxHeldUnexpiredCreditIsSentNotReRequested(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("outbox-held-credit", goakt.WithPubSub())
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
	if _, err = system.Spawn(ctx, "held-credit-commit-probe", &committedTopicProbe{committed: committed}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-committed:
	case <-time.After(time.Second):
		t.Fatal("TargetTaskCommitted subscription not acknowledged")
	}
	target := spawnTaskPeer(t, ctx, system, "held-credit-target")
	payload := []byte("held credit payload")
	digest := sha256Sum(payload)
	item := application.DurableActorTaskOutboxItem{TaskID: "client:pm:held:chain:1", Target: application.CommunicationPeer{StableID: "target-agent"}, TargetRef: actorRefOf("target-agent", target.pid), RequestID: "request-held", DedupeID: "held", ChainID: "chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 4, Mode: application.BridgeMessageTell, Payload: payload, PayloadDigest: digest, Credit: application.TaskCredit{TaskID: "client:pm:held:chain:1", CreditID: "credit-held", TargetEpoch: 7, ExpiresAt: time.Now().Add(30 * time.Second), PayloadDigest: digest}, State: "pending_credit"}
	source := restoredOutboxSource(t, ctx, system, "held-credit-source", item)
	// A stale backpressure reply (for example the expiry notice of an older
	// overlapping request) resets the state label; it must not discard the
	// live credit into a re-request churn.
	if err = system.NoSender().Tell(ctx, source, &application.TaskBackpressured{TaskID: item.TaskID, TargetEpoch: 7, Reason: "durable persistence is busy", RetryAfter: time.Millisecond}); err != nil {
		t.Fatal(err)
	}
	task, ok := target.waitFor("task", 2*time.Second).(*application.ActorTask)
	if !ok {
		t.Fatal("outbox item holding an unexpired credit never sent the actor task")
	}
	if task.Credit.CreditID != "credit-held" || task.Credit.TargetEpoch != 7 || string(task.Payload) != string(payload) {
		t.Fatalf("redrive sent the wrong credit or payload: %#v", task.Credit)
	}
	// Retire the item so the retry loop stops, then prove no credit request
	// ever left the source across several retry ticks.
	if err = target.tell(ctx, source, &application.ActorTaskAccepted{TaskID: item.TaskID, CreditID: "credit-held", TargetAgentID: "target-agent", Accepted: true}); err != nil {
		t.Fatal(err)
	}
	select {
	case message := <-committed:
		if message == nil || message.TaskID != item.TaskID {
			t.Fatalf("held-credit acceptance published the wrong commit: %#v", message)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("held-credit acceptance never published its commit")
	}
	time.Sleep(300 * time.Millisecond)
	if requests := countProbeMessages(target, func(message any) bool { _, ok := message.(*application.RequestTaskCredit); return ok }); requests != 0 {
		t.Fatalf("item holding an unexpired credit re-requested credit %d times", requests)
	}
}

// TestOutboxCreditRequestIsSingleFlightWhileGrantAwaited pins PM fix 2: while
// a credit request is awaited within its bounded window, overlapping retry
// ticks stay silent instead of stacking requests that rotate the target epoch.
func TestOutboxCreditRequestIsSingleFlightWhileGrantAwaited(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("outbox-single-flight", goakt.WithPubSub())
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
	if _, err = system.Spawn(ctx, "single-flight-commit-probe", &committedTopicProbe{committed: committed}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-committed:
	case <-time.After(time.Second):
		t.Fatal("TargetTaskCommitted subscription not acknowledged")
	}
	target := spawnTaskPeer(t, ctx, system, "single-flight-target")
	payload := []byte("single flight payload")
	digest := sha256Sum(payload)
	item := application.DurableActorTaskOutboxItem{TaskID: "client:pm:single:chain:1", Target: application.CommunicationPeer{StableID: "target-agent"}, TargetRef: actorRefOf("target-agent", target.pid), RequestID: "request-single", DedupeID: "single", ChainID: "chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 4, Mode: application.BridgeMessageTell, Payload: payload, PayloadDigest: digest, State: "pending_credit"}
	source := restoredOutboxSource(t, ctx, system, "single-flight-source", item)
	// The slow target delays its grant across several retry ticks.
	request, ok := target.waitForCreditRequest(2 * time.Second)
	if !ok {
		t.Fatal("restored item never requested credit")
	}
	time.Sleep(350 * time.Millisecond)
	if requests := target.creditRequestCount(); requests != 1 {
		t.Fatalf("overlapping retries fired %d credit requests while the grant was awaited, want 1", requests)
	}
	if err = target.tell(ctx, source, &application.TaskCreditGranted{Credit: application.TaskCredit{TaskID: item.TaskID, CreditID: "credit-single", TargetEpoch: 1, ExpiresAt: time.Now().Add(30 * time.Second), PayloadDigest: request.PayloadDigest}}); err != nil {
		t.Fatal(err)
	}
	task, ok := target.waitFor("task", 2*time.Second).(*application.ActorTask)
	if !ok {
		t.Fatal("granted credit never produced the actor task send")
	}
	if task.Credit.CreditID != "credit-single" {
		t.Fatalf("task carried the wrong credit: %#v", task.Credit)
	}
	if err = target.tell(ctx, source, &application.ActorTaskAccepted{TaskID: item.TaskID, CreditID: "credit-single", TargetAgentID: "target-agent", Accepted: true}); err != nil {
		t.Fatal(err)
	}
	select {
	case message := <-committed:
		if message == nil || message.TaskID != item.TaskID {
			t.Fatalf("single-flight acceptance published the wrong commit: %#v", message)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("single-flight acceptance never published its commit")
	}
	time.Sleep(200 * time.Millisecond)
	if requests := target.creditRequestCount(); requests != 1 {
		t.Fatalf("credit request count settled at %d, want exactly 1", requests)
	}
}

// TestStaleBackpressureMustNotChurnTargetCreditEpoch pins the live failure
// signature: a stale backpressure reply must not push an item holding an
// unconsumed credit back into a re-request loop that rotates the target's
// credit epoch while the daemon logs nothing.
func TestStaleBackpressureMustNotChurnTargetCreditEpoch(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("outbox-epoch-churn")
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
	// A real target agent whose bridge is deliberately not connected: credit
	// grants flow, task acceptance is refused, and every state change is
	// recorded by the store for the epoch audit.
	targetStore := &recordingStore{notify: make(chan struct{}, 16)}
	targetWriter, err := system.Spawn(ctx, "churn-target-writer", &actors.HostedStateWriterActor{Store: targetStore})
	if err != nil {
		t.Fatal(err)
	}
	targetBinding := application.InactiveHostedPiRuntimeBinding()
	targetBinding.State = application.HostedPiRuntimeReady
	targetBinding.RuntimeID = "runtime-bravo"
	targetBinding.Incarnation = 1
	targetRecord := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "bravo", Binding: targetBinding, AgentState: application.DurableAgentState{}}
	target, err := system.Spawn(ctx, "agent-bravo", actors.NewAgentActor(&application.RegisterAgent{AgentID: "bravo", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: "runtime-bravo"}, HostedPiRuntime: targetBinding, AllowedCapability: []string{"send"}, PersistencePID: targetWriter, DurableRecord: &targetRecord}))
	if err != nil {
		t.Fatal(err)
	}
	source := restoredOutboxSource(t, ctx, system, "churn-source")
	payload := []byte("churn payload")
	taskID := "client:pm:churn:chain:1"
	receipt := make(chan application.BridgeIntentResult, 1)
	send := &application.SendActorTask{TargetPID: target, TargetPeer: application.CommunicationPeer{StableID: "bravo"}, RequestID: "request-churn", DedupeID: "churn", ChainID: "chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 4, Mode: application.BridgeMessageTell, Payload: payload, Receipt: receipt}
	if err = system.NoSender().Tell(ctx, source, send); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-receipt:
		if !result.Accepted || result.Reason != "stored_pending_credit" {
			t.Fatalf("churn admission failed: %#v", result)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("churn admission receipt missing")
	}
	granted := targetStore.waitForReservation(t, taskID, 2*time.Second)
	if granted.AgentState.TaskCreditEpoch != 1 {
		t.Fatalf("first grant rotated the epoch to %d, want 1", granted.AgentState.TaskCreditEpoch)
	}
	// Inject the stale backpressure reply that used to discard the live credit.
	if err = system.NoSender().Tell(ctx, source, &application.TaskBackpressured{TaskID: taskID, TargetEpoch: 1, Reason: "durable persistence is busy", RetryAfter: time.Millisecond}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(700 * time.Millisecond)
	maxEpoch, reservations := uint64(0), 0
	for _, record := range targetStore.all() {
		if record.AgentState.TaskCreditEpoch > maxEpoch {
			maxEpoch = record.AgentState.TaskCreditEpoch
		}
		for _, reservation := range record.AgentState.TaskCreditReservations {
			if reservation.Credit.TaskID == taskID {
				reservations++
			}
		}
	}
	if maxEpoch != 1 || reservations != 1 {
		t.Fatalf("stale backpressure churned the target credit epoch: max_epoch=%d reservations=%d, want exactly 1 and 1", maxEpoch, reservations)
	}
	// The item must still be pending delivery, not terminal.
	replay := make(chan application.BridgeIntentResult, 1)
	replaySend := *send
	replaySend.Receipt = replay
	if err = system.NoSender().Tell(ctx, source, &replaySend); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-replay:
		if !result.Accepted || result.Reason != "stored_pending_credit" {
			t.Fatalf("churn item left the pending state: %#v", result)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("churn replay receipt missing")
	}
}

// TestSlowTargetDeliversActorTaskExactlyOnce proves the required end-to-end
// property: overlapping outbox retries against a slow target still deliver the
// task exactly once, spend exactly one credit epoch, and publish exactly one
// commit.
func TestSlowTargetDeliversActorTaskExactlyOnce(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("outbox-slow-target", goakt.WithPubSub())
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
	if _, err = system.Spawn(ctx, "slow-target-commit-probe", &committedTopicProbe{committed: committed}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-committed:
	case <-time.After(time.Second):
		t.Fatal("TargetTaskCommitted subscription not acknowledged")
	}
	// A real connected target whose every durable round-trip (grant and
	// acceptance) is slow, so the source retry ticks overlap the grant window.
	targetStore := &slowSaveStore{notify: make(chan struct{}, 16), delay: 250 * time.Millisecond}
	targetWriter, err := system.Spawn(ctx, "slow-target-writer", &actors.HostedStateWriterActor{Store: targetStore})
	if err != nil {
		t.Fatal(err)
	}
	targetBinding := application.InactiveHostedPiRuntimeBinding()
	targetBinding.State = application.HostedPiRuntimeReady
	targetBinding.BridgeReady = true
	targetBinding.RuntimeID = "runtime-slow"
	targetBinding.Incarnation = 1
	targetState := application.DurableAgentState{Fence: 1, BridgeFence: 1, BridgeReady: true, BridgeDeclaredReady: true, BridgeSession: "session", BridgeGeneration: "generation", BridgePrincipal: "hosted:alpha", BridgeHandle: "handle", BridgePiSession: "pi", Attachments: []application.DurableAttachment{{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: "handle", Fence: 1, Capabilities: []string{"send", "hosted_bridge"}}}}
	targetRecord := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "bravo", Binding: targetBinding, AgentState: targetState}
	target, err := system.Spawn(ctx, "agent-slow-bravo", actors.NewAgentActor(&application.RegisterAgent{AgentID: "bravo", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: "runtime-slow"}, HostedPiRuntime: targetBinding, AllowedCapability: []string{"send", "hosted_bridge"}, PersistencePID: targetWriter, DurableRecord: &targetRecord}))
	if err != nil {
		t.Fatal(err)
	}
	source := restoredOutboxSource(t, ctx, system, "slow-target-source")
	payload := []byte("slow target payload")
	taskID := "client:pm:slow:chain:1"
	receipt := make(chan application.BridgeIntentResult, 1)
	send := &application.SendActorTask{TargetPID: target, TargetPeer: application.CommunicationPeer{StableID: "bravo"}, RequestID: "request-slow", DedupeID: "slow", ChainID: "chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 4, Mode: application.BridgeMessageTell, Payload: payload, Receipt: receipt}
	if err = system.NoSender().Tell(ctx, source, send); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-receipt:
		if !result.Accepted || result.Reason != "stored_pending_credit" {
			t.Fatalf("slow-target admission failed: %#v", result)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("slow-target admission receipt missing")
	}
	select {
	case message := <-committed:
		if message == nil || message.TaskID != taskID {
			t.Fatalf("slow-target commit carried the wrong task: %#v", message)
		}
	case <-time.After(6 * time.Second):
		t.Fatal("slow target never committed the actor task")
	}
	select {
	case extra := <-committed:
		if extra != nil {
			t.Fatalf("slow target committed the task more than once: %#v", extra)
		}
	case <-time.After(400 * time.Millisecond):
	}
	deliveries, maxEpoch, reservations := 0, uint64(0), 0
	for _, record := range targetStore.all() {
		if record.AgentState.TaskCreditEpoch > maxEpoch {
			maxEpoch = record.AgentState.TaskCreditEpoch
		}
		for _, reservation := range record.AgentState.TaskCreditReservations {
			if reservation.Credit.TaskID == taskID {
				reservations++
			}
		}
		for _, delivery := range record.AgentState.BridgeDeliveries {
			if delivery.DedupeID == "slow" {
				deliveries++
			}
		}
	}
	if deliveries != 1 {
		t.Fatalf("slow target recorded %d deliveries for the task, want exactly 1", deliveries)
	}
	if maxEpoch != 1 || reservations != 1 {
		t.Fatalf("slow target spent %d credit epochs and %d reservations, want exactly 1 and 1", maxEpoch, reservations)
	}
}
