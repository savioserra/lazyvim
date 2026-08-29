package actors

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

type taskTargetProbe struct {
	pid      *actor.PID
	mu       sync.Mutex
	received []any
	notify   chan struct{}
}

func (*taskTargetProbe) PreStart(*actor.Context) error { return nil }
func (*taskTargetProbe) PostStop(*actor.Context) error { return nil }
func (p *taskTargetProbe) Receive(ctx *actor.ReceiveContext) {
	p.mu.Lock()
	p.received = append(p.received, ctx.Message())
	p.mu.Unlock()
	select {
	case p.notify <- struct{}{}:
	default:
	}
}

func (p *taskTargetProbe) creditRequests() []application.RequestTaskCredit {
	p.mu.Lock()
	defer p.mu.Unlock()
	var requests []application.RequestTaskCredit
	for _, message := range p.received {
		if request, ok := message.(*application.RequestTaskCredit); ok {
			requests = append(requests, *request)
		}
	}
	return requests
}

func (p *taskTargetProbe) waitForCreditRequest(timeout time.Duration) *application.RequestTaskCredit {
	deadline := time.After(timeout)
	for {
		if request := p.creditRequests(); len(request) > 0 {
			return &request[0]
		}
		select {
		case <-p.notify:
		case <-deadline:
			return nil
		}
	}
}

func newTaskTargetProbe(t *testing.T, ctx context.Context, system actor.ActorSystem) *taskTargetProbe {
	t.Helper()
	probe := &taskTargetProbe{notify: make(chan struct{}, 8)}
	pid, err := system.Spawn(ctx, "task-target-probe", probe)
	if err != nil {
		t.Fatal(err)
	}
	probe.pid = pid
	return probe
}

func TestSendActorTaskInterleaveKeepsFirstReceiptDuringInflightFsync(t *testing.T) {
	ctx := context.Background()
	system, err := actor.NewActorSystem("task-interleave-test")
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
	store := &blockingStore{started: make(chan application.DurableHostedRecord, 1), release: make(chan error, 1)}
	writer, err := system.Spawn(ctx, "task-source-writer", &HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	binding := application.InactiveHostedPiRuntimeBinding()
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, OwnerUID: 0, AgentID: "client:pm", Binding: binding}
	source, err := system.Spawn(ctx, "task-source", NewAgentActor(&application.RegisterAgent{AgentID: "client:pm", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "client:pm"}, HostedPiRuntime: binding, Retention: "bounded", Recovery: "terminal-reattach", PersistencePID: writer, DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	target := newTaskTargetProbe(t, ctx, system)
	task := func(dedupe, chain string, sequence uint64, receipt chan application.BridgeIntentResult) *application.SendActorTask {
		return &application.SendActorTask{TargetPID: target.pid, TargetPeer: application.CommunicationPeer{StableID: "target-agent"}, RequestID: "request-" + dedupe, DedupeID: dedupe, ChainID: chain, RequiredCapability: "send", SourceMutationSequence: sequence, Deadline: time.Now().Add(time.Minute), HopLimit: 4, Mode: application.BridgeMessageTell, Payload: []byte("payload " + dedupe), Receipt: receipt}
	}
	first, second := make(chan application.BridgeIntentResult, 1), make(chan application.BridgeIntentResult, 1)
	if err = system.NoSender().Tell(ctx, source, task("dedupe-1", "chain-1", 1, first)); err != nil {
		t.Fatal(err)
	}
	select {
	case persisted := <-store.started:
		if len(persisted.AgentState.SourceOutbox) != 1 || persisted.AgentState.SourceOutbox[0].TaskID != "client:pm:dedupe-1:chain-1:1" {
			t.Fatalf("first fsync state missing stored_pending_credit outbox item: %#v", persisted.AgentState.SourceOutbox)
		}
	case result := <-first:
		t.Fatalf("first task settled before fsync: %#v", result)
	case <-time.After(time.Second):
		t.Fatal("first fsync did not start")
	}
	// A second SendActorTask arriving while the first fsync is in flight must be
	// rejected fail-closed and must not drop the first receipt or its effects.
	if err = system.NoSender().Tell(ctx, source, task("dedupe-2", "chain-2", 2, second)); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-second:
		if result.Accepted || result.Reason != "durable persistence is busy" {
			t.Fatalf("second task during in-flight fsync was not rejected fail-closed: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("second task receipt missing")
	}
	select {
	case persisted := <-store.started:
		t.Fatalf("second task started an overlapping fsync: %#v", persisted.AgentState.SourceOutbox)
	case <-time.After(150 * time.Millisecond):
	}
	store.release <- nil
	select {
	case result := <-first:
		if !result.Accepted || !result.AwaitingAck || result.Reason != "stored_pending_credit" {
			t.Fatalf("first task receipt was dropped or corrupted: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("first task receipt missing after fsync completed")
	}
	if request := target.waitForCreditRequest(time.Second); request == nil || request.TaskID != "client:pm:dedupe-1:chain-1:1" {
		t.Fatalf("credit request effect missing or wrong: %#v", request)
	}
	requests := target.creditRequests()
	if len(requests) != 1 || requests[0].TaskID != "client:pm:dedupe-1:chain-1:1" {
		t.Fatalf("credit requests did not carry exactly the first task: %#v", requests)
	}
}
