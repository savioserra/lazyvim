package actors_test

import (
	"context"
	"crypto/sha256"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
)

func sha256Sum(payload []byte) [32]byte { return sha256.Sum256(payload) }

// hookedStore is a durable store whose Save passes through an optional
// test-controlled hook: the hook can block the fsync (opening the crash
// window) or inject a one-shot persistence failure.
type hookedStore struct {
	mu      sync.Mutex
	records []application.DurableHostedRecord
	notify  chan struct{}
	hook    func(application.DurableHostedRecord) error
}

func (s *hookedStore) Save(_ context.Context, r application.DurableHostedRecord) error {
	s.mu.Lock()
	hook := s.hook
	s.mu.Unlock()
	if hook != nil {
		if err := hook(r); err != nil {
			return err
		}
	}
	s.mu.Lock()
	s.records = append(s.records, r)
	s.mu.Unlock()
	select {
	case s.notify <- struct{}{}:
	default:
	}
	return nil
}

func (*hookedStore) Remove(context.Context, string) error { return nil }

func (s *hookedStore) setHook(hook func(application.DurableHostedRecord) error) {
	s.mu.Lock()
	s.hook = hook
	s.mu.Unlock()
}

func (s *hookedStore) last() application.DurableHostedRecord {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.records[len(s.records)-1]
}

// retirementHarness drives a durable hosted agent with one live actor-task
// delivery from a reserved source probe.
type retirementHarness struct {
	system goakt.ActorSystem
	agent  *goakt.PID
	store  *hookedStore
	source *taskPeerProbe
	handle string
	fence  uint64
}

func newRetirementHarness(t *testing.T, name string) *retirementHarness {
	t.Helper()
	ctx := context.Background()
	system, err := goakt.NewActorSystem(name)
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
	store := &hookedStore{notify: make(chan struct{}, 16)}
	writer, err := system.Spawn(ctx, name+"-writer", &actors.HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.State, binding.BridgeReady, binding.RuntimeID, binding.Incarnation = application.HostedPiRuntimeDegraded, true, "runtime-retire", 1
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "retire-agent", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: "runtime-retire"}, Binding: binding, AgentState: application.DurableAgentState{BridgeReady: true, BridgeDeclaredReady: true}}
	agent, err := system.Spawn(ctx, name+"-agent", actors.NewAgentActor(&application.RegisterAgent{AgentID: "retire-agent", AuthorityBinding: record.AuthorityBinding, HostedPiRuntime: binding, AllowedCapability: []string{"send", "ask", "hosted_bridge"}, PersistencePID: writer, DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	source := spawnTaskPeer(t, ctx, system, name+"-source")
	attach := make(chan application.AttachResult, 1)
	if err = system.NoSender().Tell(ctx, agent, &application.AttachAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", RequestedCapabilities: []string{"send", "ask", "hosted_bridge"}, IssuedHandle: "handle", Result: attach}); err != nil {
		t.Fatal(err)
	}
	h := &retirementHarness{system: system, agent: agent, store: store, source: source}
	select {
	case attached := <-attach:
		if !attached.Completed {
			t.Fatalf("attach failed: %#v", attached)
		}
		h.handle, h.fence = attached.Handle, attached.Fence
	case <-time.After(2 * time.Second):
		t.Fatal("attach timed out")
	}
	connected := make(chan application.BridgeResult, 1)
	if err = system.NoSender().Tell(ctx, agent, &application.BridgeConnect{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", AgentID: "retire-agent", Handle: h.handle, Fence: h.fence, RuntimeID: "runtime-retire", Incarnation: 1, PiSessionID: "pi-retire", Result: connected}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-connected:
		if !result.Accepted {
			t.Fatalf("bridge connect failed: %#v", result)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("bridge connect timed out")
	}
	return h
}

// admitLiveTask drives the reserved source probe through the full credit flow
// so the agent retains one delivery with a live taskSources PID.
func (h *retirementHarness) admitLiveTask(t *testing.T, digest [32]byte) application.BridgeDelivery {
	t.Helper()
	ctx := context.Background()
	if err := h.source.tell(ctx, h.agent, &application.RequestTaskCredit{TaskID: "retire-agent:retire-dedupe:retire-chain:1", RequestID: "retire-request", DedupeID: "retire-dedupe", ChainID: "retire-chain", Deadline: time.Now().Add(time.Minute), PayloadDigest: digest}); err != nil {
		t.Fatal(err)
	}
	granted, ok := h.source.waitFor("credit", 2*time.Second).(*application.TaskCreditGranted)
	if !ok {
		t.Fatal("reserved source never received the granted credit")
	}
	task := &application.ActorTask{Credit: granted.Credit, SourcePeer: application.CommunicationPeer{StableID: "client:alpha"}, TargetPeer: application.CommunicationPeer{StableID: "retire-agent"}, RequestID: "retire-request", DedupeID: "retire-dedupe", ChainID: "retire-chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: []byte("retire payload")}
	if err := h.source.tell(ctx, h.agent, task); err != nil {
		t.Fatal(err)
	}
	accepted, ok := h.source.waitFor("accepted", 2*time.Second).(*application.ActorTaskAccepted)
	if !ok || !accepted.Accepted {
		t.Fatalf("reserved source task was not accepted: %#v", accepted)
	}
	poll, err := h.system.NoSender().Ask(ctx, h.agent, &application.PollBridge{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: h.handle, Fence: h.fence, MaxItems: 8}, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	deliveries := poll.(*application.BridgePollResult).Deliveries
	if len(deliveries) != 1 {
		t.Fatalf("expected exactly one retained delivery: %#v", deliveries)
	}
	return deliveries[0]
}

func (h *retirementHarness) retire(t *testing.T) {
	t.Helper()
	err := h.system.NoSender().Tell(context.Background(), h.agent, &application.HostedPiRuntimeStateChanged{AgentID: "retire-agent", Binding: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, RuntimeID: "runtime-retire", Incarnation: 2}, Reason: "runtime restarted"})
	if err != nil {
		t.Fatal(err)
	}
}

// assertNoExtraCompletion fails when more than one terminal completion for
// the same key reached the reserved source.
func (h *retirementHarness) assertNoExtraCompletion(t *testing.T, completionKey string) {
	t.Helper()
	h.source.mu.Lock()
	messages := append([]any(nil), h.source.received...)
	h.source.mu.Unlock()
	seen := 0
	for _, message := range messages {
		if completed, ok := message.(*application.ActorTaskCompleted); ok && completed.CompletionKey == completionKey {
			seen++
		}
	}
	if seen > 1 {
		t.Fatalf("retirement completion emitted %d times for one delivery", seen)
	}
}

// TestIncarnationRetirementEffectsWaitForDurablePersist proves the crash
// window: the whole retirement terminal-failure batch (delivery retirement,
// completion tells, bridge-binding wipe, binding swap) emits its effects only
// after the durable persist confirms. While the fsync is blocked the source
// observes no completion at all.
func TestIncarnationRetirementEffectsWaitForDurablePersist(t *testing.T) {
	h := newRetirementHarness(t, "retire-crash-window")
	delivery := h.admitLiveTask(t, sha256Sum([]byte("retire payload")))
	if delivery.CompletionKey == "" {
		t.Fatal("live task delivery lacks a completion key")
	}
	entered := make(chan struct{}, 1)
	release := make(chan struct{})
	h.store.setHook(func(application.DurableHostedRecord) error {
		select {
		case entered <- struct{}{}:
		default:
		}
		<-release
		return nil
	})
	h.retire(t)
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("retirement never opened its durable persistence window")
	}
	// Crash window: the mutation happened but the fsync is unconfirmed, so no
	// terminal completion may have reached the source yet.
	if leaked := h.source.waitFor("completed", 200*time.Millisecond); leaked != nil {
		t.Fatalf("retirement completion emitted before durable persist confirmed: %#v", leaked)
	}
	// The agent reports the pending persistence window instead of the retired
	// state: polls must fail closed while the batch is unconfirmed.
	poll, err := h.system.NoSender().Ask(context.Background(), h.agent, &application.PollBridge{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: h.handle, Fence: h.fence, MaxItems: 8}, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if result, ok := poll.(*application.BridgePollResult); !ok || result.Reason == "" || len(result.Deliveries) != 0 {
		t.Fatalf("poll during the crash window did not fail closed: %#v", poll)
	}
	close(release)
	completed, ok := h.source.waitFor("completed", 3*time.Second).(*application.ActorTaskCompleted)
	if !ok {
		t.Fatal("retirement completion missing after durable confirm")
	}
	if completed.CompletionKey != delivery.CompletionKey || completed.Terminal.Reason != "hosted runtime incarnation retired" {
		t.Fatalf("retirement completion carried the wrong terminal: %#v", completed)
	}
	time.Sleep(150 * time.Millisecond)
	h.assertNoExtraCompletion(t, completed.CompletionKey)
	persisted := h.store.last()
	if len(persisted.AgentState.BridgeDeliveries) != 0 || persisted.AgentState.BridgeSession != "" || persisted.Binding.Incarnation != 2 {
		t.Fatalf("retirement batch was not durably retained: %#v", persisted.AgentState)
	}
}

// TestIncarnationRetirementPersistenceFailureRollsBackAndRedrives proves the
// rollback half of the same window: a failed persist emits no effects, rolls
// the whole batch back (deliveries, bridge binding, runtime binding), and the
// re-driven state change then commits the retirement exactly once.
func TestIncarnationRetirementPersistenceFailureRollsBackAndRedrives(t *testing.T) {
	h := newRetirementHarness(t, "retire-rollback")
	delivery := h.admitLiveTask(t, sha256Sum([]byte("retire payload")))
	var failures atomic.Int32
	injected := make(chan struct{})
	h.store.setHook(func(record application.DurableHostedRecord) error {
		if failures.Add(1) == 1 && len(record.AgentState.BridgeDeliveries) == 0 && record.Binding.Incarnation == 2 {
			close(injected)
			return errors.New("injected retirement persistence failure")
		}
		return nil
	})
	h.retire(t)
	select {
	case <-injected:
	case <-time.After(2 * time.Second):
		t.Fatal("injected failure never fired for the retirement batch")
	}
	// The re-driven retirement must eventually commit and deliver exactly one
	// terminal completion to the reserved source.
	completed, ok := h.source.waitFor("completed", 4*time.Second).(*application.ActorTaskCompleted)
	if !ok {
		t.Fatal("rolled-back retirement never redrove its completion")
	}
	if completed.CompletionKey != delivery.CompletionKey || completed.Terminal.Reason != "hosted runtime incarnation retired" {
		t.Fatalf("redriven retirement completion carried the wrong terminal: %#v", completed)
	}
	time.Sleep(150 * time.Millisecond)
	h.assertNoExtraCompletion(t, completed.CompletionKey)
	persisted := h.store.last()
	if len(persisted.AgentState.BridgeDeliveries) != 0 || persisted.Binding.Incarnation != 2 {
		t.Fatalf("redriven retirement never committed durably: %#v", persisted)
	}
}
