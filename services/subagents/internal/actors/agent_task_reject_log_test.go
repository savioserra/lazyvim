package actors

import (
	"context"
	"crypto/sha256"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

type rejectLogProbe struct {
	pid      *actor.PID
	mu       sync.Mutex
	received []any
	scanned  int
	notify   chan struct{}
}

func (*rejectLogProbe) PreStart(*actor.Context) error { return nil }
func (*rejectLogProbe) PostStop(*actor.Context) error { return nil }
func (p *rejectLogProbe) Receive(ctx *actor.ReceiveContext) {
	p.mu.Lock()
	p.received = append(p.received, ctx.Message())
	p.mu.Unlock()
	select {
	case p.notify <- struct{}{}:
	default:
	}
}

func (p *rejectLogProbe) tell(ctx context.Context, target *actor.PID, message any) error {
	return p.pid.Tell(ctx, target, message)
}

func (p *rejectLogProbe) waitFor(kind string, timeout time.Duration) any {
	deadline := time.After(timeout)
	for {
		p.mu.Lock()
		for p.scanned < len(p.received) {
			message := p.received[p.scanned]
			p.scanned++
			switch kind {
			case "credit":
				if value, ok := message.(*application.TaskCreditGranted); ok {
					p.mu.Unlock()
					return value
				}
			case "accepted":
				if value, ok := message.(*application.ActorTaskAccepted); ok {
					p.mu.Unlock()
					return value
				}
			}
		}
		p.mu.Unlock()
		select {
		case <-p.notify:
		case <-deadline:
			return nil
		}
	}
}

// TestActorTaskRejectLoggingIsBoundedAndSpecific pins PM fixes: every rejected
// ActorTask Tell is now visible with its epoch/expiry/sender/digest reason, a
// stale-epoch or consumed credit never double-delivers, and the log stays
// bounded under a churny source.
func TestActorTaskRejectLoggingIsBoundedAndSpecific(t *testing.T) {
	ctx := context.Background()
	system, err := actor.NewActorSystem("task-reject-log", actor.WithPubSub())
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
	store := &recordingRejectStore{notify: make(chan struct{}, 16)}
	writer, err := system.Spawn(ctx, "reject-log-writer", &HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	var logMu sync.Mutex
	var lines []string
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.State = application.HostedPiRuntimeReady
	binding.BridgeReady = true
	binding.RuntimeID = "runtime-reject"
	binding.Incarnation = 1
	state := application.DurableAgentState{Fence: 1, BridgeFence: 1, BridgeReady: true, BridgeDeclaredReady: true, BridgeSession: "session", BridgeGeneration: "generation", BridgePrincipal: "hosted:alpha", BridgeHandle: "handle", BridgePiSession: "pi", Attachments: []application.DurableAttachment{{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: "handle", Fence: 1, Capabilities: []string{"send", "hosted_bridge"}}}}
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "bravo", Binding: binding, AgentState: state}
	agent := NewAgentActor(&application.RegisterAgent{AgentID: "bravo", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: "runtime-reject"}, HostedPiRuntime: binding, AllowedCapability: []string{"send"}, PersistencePID: writer, DurableRecord: &record})
	agent.taskRejectLog = func(format string, args ...any) {
		logMu.Lock()
		defer logMu.Unlock()
		lines = append(lines, fmt.Sprintf(format, args...))
	}
	target, err := system.Spawn(ctx, "agent-reject-bravo", agent)
	if err != nil {
		t.Fatal(err)
	}
	reserved := &rejectLogProbe{notify: make(chan struct{}, 16)}
	if reserved.pid, err = system.Spawn(ctx, "reject-reserved-source", reserved); err != nil {
		t.Fatal(err)
	}
	rogue := &rejectLogProbe{notify: make(chan struct{}, 16)}
	if rogue.pid, err = system.Spawn(ctx, "reject-rogue-source", rogue); err != nil {
		t.Fatal(err)
	}
	logCount := func() int {
		logMu.Lock()
		defer logMu.Unlock()
		return len(lines)
	}
	payload := []byte("reject log payload")
	digest := sha256.Sum256(payload)
	taskID := "client:pm:reject:chain:1"
	if err = reserved.tell(ctx, target, &application.RequestTaskCredit{TaskID: taskID, RequestID: "request-reject", DedupeID: "reject", ChainID: "chain", Deadline: time.Now().Add(time.Minute), PayloadDigest: digest}); err != nil {
		t.Fatal(err)
	}
	granted, ok := reserved.waitFor("credit", time.Second).(*application.TaskCreditGranted)
	if !ok {
		t.Fatal("reserved source never received the granted credit")
	}
	task := &application.ActorTask{Credit: granted.Credit, SourcePeer: application.CommunicationPeer{StableID: "client:pm"}, TargetPeer: application.CommunicationPeer{StableID: "bravo"}, RequestID: "request-reject", DedupeID: "reject", ChainID: "chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: payload}
	// A different sender spending the reserved credit: rejected and logged
	// with the sender detail.
	if err = rogue.tell(ctx, target, task); err != nil {
		t.Fatal(err)
	}
	if rejected, ok := rogue.waitFor("accepted", time.Second).(*application.ActorTaskAccepted); !ok || rejected.Accepted || rejected.Reason != "task credit sender identity rejected" {
		t.Fatalf("rogue sender was not rejected fail-closed: %#v", rejected)
	}
	if logCount() != 1 || !strings.Contains(lines[0], "reason=sender_identity_rejected") || !strings.Contains(lines[0], "sender_ok=false") {
		t.Fatalf("sender-identity reject was not logged with its detail: %q", lines)
	}
	// Stale-epoch credit: rejected and logged with the epoch detail.
	staleEpoch := *task
	staleEpoch.Credit.TargetEpoch = granted.Credit.TargetEpoch + 100
	if err = reserved.tell(ctx, target, &staleEpoch); err != nil {
		t.Fatal(err)
	}
	if rejected, ok := reserved.waitFor("accepted", time.Second).(*application.ActorTaskAccepted); !ok || rejected.Accepted {
		t.Fatalf("stale-epoch credit was not rejected: %#v", rejected)
	}
	if logCount() != 2 || !strings.Contains(lines[1], "reason=credit_epoch_mismatch") || !strings.Contains(lines[1], "epoch=") || !strings.Contains(lines[1], "target_epoch=") {
		t.Fatalf("stale-epoch reject was not logged with epoch detail: %q", lines)
	}
	// Payload digest mismatch: rejected and logged with the digest detail.
	wrongPayload := *task
	wrongPayload.Payload = []byte("tampered payload")
	if err = reserved.tell(ctx, target, &wrongPayload); err != nil {
		t.Fatal(err)
	}
	if rejected, ok := reserved.waitFor("accepted", time.Second).(*application.ActorTaskAccepted); !ok || rejected.Accepted {
		t.Fatalf("tampered payload was not rejected: %#v", rejected)
	}
	if logCount() != 3 || !strings.Contains(lines[2], "reason=payload_digest_mismatch") {
		t.Fatalf("digest reject was not logged with its detail: %q", lines)
	}
	// The valid spend succeeds without producing a reject log line.
	before := logCount()
	if err = reserved.tell(ctx, target, task); err != nil {
		t.Fatal(err)
	}
	if accepted, ok := reserved.waitFor("accepted", time.Second).(*application.ActorTaskAccepted); !ok || !accepted.Accepted {
		t.Fatalf("valid task was not accepted: %#v", accepted)
	}
	if logCount() != before {
		t.Fatalf("accepted task produced reject log lines: %q", lines)
	}
	// Stale-epoch regression: re-sending the consumed credit must be rejected
	// and logged, and must never double-deliver.
	if err = reserved.tell(ctx, target, task); err != nil {
		t.Fatal(err)
	}
	if rejected, ok := reserved.waitFor("accepted", time.Second).(*application.ActorTaskAccepted); !ok || rejected.Accepted {
		t.Fatalf("consumed credit was not rejected: %#v", rejected)
	}
	if logCount() != before+1 || !strings.Contains(lines[before], "reason=credit_reservation_missing") || !strings.Contains(lines[before], "reserved=false") {
		t.Fatalf("consumed-credit reject was not logged with its detail: %q", lines)
	}
	var deliveries int
	for _, saved := range store.all() {
		for _, delivery := range saved.AgentState.BridgeDeliveries {
			if delivery.DedupeID == "reject" {
				deliveries++
			}
		}
	}
	if deliveries != 1 {
		t.Fatalf("rejected re-sends produced %d deliveries, want exactly 1", deliveries)
	}
	// The log is bounded: a churny redriver cannot flood it.
	for range 40 {
		if err = rogue.tell(ctx, target, task); err != nil {
			t.Fatal(err)
		}
	}
	floodDeadline := time.After(2 * time.Second)
	for logCount() < maxActorTaskRejectLogs {
		rogue.waitFor("accepted", 200*time.Millisecond)
		select {
		case <-floodDeadline:
			t.Fatalf("reject log never reached its bound: %d lines", logCount())
		default:
		}
	}
	time.Sleep(200 * time.Millisecond)
	if count := logCount(); count != maxActorTaskRejectLogs {
		t.Fatalf("reject log settled at %d lines, want the bound %d", count, maxActorTaskRejectLogs)
	}
	if !strings.Contains(lines[0], "actor task rejected: agent=bravo") || !strings.Contains(lines[0], fmt.Sprintf("task=%s", taskID)) {
		t.Fatalf("reject log line lost its bounded identity fields: %q", lines[0])
	}
}

type recordingRejectStore struct {
	mu      sync.Mutex
	records []application.DurableHostedRecord
	notify  chan struct{}
}

func (s *recordingRejectStore) Save(_ context.Context, r application.DurableHostedRecord) error {
	s.mu.Lock()
	s.records = append(s.records, r)
	s.mu.Unlock()
	select {
	case s.notify <- struct{}{}:
	default:
	}
	return nil
}
func (*recordingRejectStore) Remove(context.Context, string) error { return nil }

func (s *recordingRejectStore) all() []application.DurableHostedRecord {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]application.DurableHostedRecord(nil), s.records...)
}
