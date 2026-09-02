package actors_test

import (
	"context"
	"crypto/sha256"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
)

type taskPeerProbe struct {
	pid      *goakt.PID
	mu       sync.Mutex
	received []any
	notify   chan struct{}
}

func (*taskPeerProbe) PreStart(*goakt.Context) error { return nil }
func (*taskPeerProbe) PostStop(*goakt.Context) error { return nil }
func (p *taskPeerProbe) tell(ctx context.Context, target *goakt.PID, message any) error {
	return p.pid.Tell(ctx, target, message)
}
func (p *taskPeerProbe) Receive(ctx *goakt.ReceiveContext) {
	p.mu.Lock()
	p.received = append(p.received, ctx.Message())
	p.mu.Unlock()
	select {
	case p.notify <- struct{}{}:
	default:
	}
}

func (p *taskPeerProbe) waitFor(kind string, timeout time.Duration) any {
	deadline := time.After(timeout)
	for {
		select {
		case <-p.notify:
		case <-deadline:
			return nil
		}
		p.mu.Lock()
		for _, message := range p.received {
			switch kind {
			case "credit":
				if _, ok := message.(*application.TaskCreditGranted); ok {
					p.mu.Unlock()
					return message
				}
			case "task":
				if _, ok := message.(*application.ActorTask); ok {
					p.mu.Unlock()
					return message
				}
			case "accepted":
				if _, ok := message.(*application.ActorTaskAccepted); ok {
					p.mu.Unlock()
					return message
				}
			case "completed":
				if _, ok := message.(*application.ActorTaskCompleted); ok {
					p.mu.Unlock()
					return message
				}
			}
		}
		p.mu.Unlock()
	}
}

type committedTopicProbe struct {
	committed chan *application.TargetTaskCommitted
}

func (*committedTopicProbe) PreStart(*goakt.Context) error { return nil }
func (*committedTopicProbe) PostStop(*goakt.Context) error { return nil }
func (p *committedTopicProbe) Receive(ctx *goakt.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *goakt.PostStart:
		ctx.Tell(ctx.ActorSystem().TopicActor(), goakt.NewSubscribe(application.TargetTaskCommittedTopic))
	case *goakt.SubscribeAck:
		select {
		case p.committed <- nil:
		default:
		}
	case *application.TargetTaskCommitted:
		select {
		case p.committed <- message:
		default:
		}
	}
}

func spawnTaskPeer(t *testing.T, ctx context.Context, system goakt.ActorSystem, name string) *taskPeerProbe {
	t.Helper()
	probe := &taskPeerProbe{notify: make(chan struct{}, 16)}
	pid, err := system.Spawn(ctx, name, probe)
	if err != nil {
		t.Fatal(err)
	}
	probe.pid = pid
	return probe
}

func TestActorTaskOriginMustMatchReservedCreditSender(t *testing.T) {
	target := newBridgeHarness(t, "task-origin-target", "bravo", "alpha")
	ctx := context.Background()
	source := spawnTaskPeer(t, ctx, target.system, "reserved-source")
	rogue := spawnTaskPeer(t, ctx, target.system, "rogue-source")
	payload := []byte("task payload")
	digest := sha256.Sum256(payload)
	creditRequest := &application.RequestTaskCredit{TaskID: "bravo-task-1", RequestID: "request-1", DedupeID: "dedupe-1", ChainID: "chain-1", Deadline: time.Now().Add(time.Minute), PayloadDigest: digest}
	if err := source.tell(ctx, target.pid, creditRequest); err != nil {
		t.Fatal(err)
	}
	granted, ok := source.waitFor("credit", time.Second).(*application.TaskCreditGranted)
	if !ok {
		t.Fatal("reserved source never received the granted credit")
	}
	task := &application.ActorTask{Credit: granted.Credit, SourcePeer: application.CommunicationPeer{StableID: "alpha"}, TargetPeer: application.CommunicationPeer{StableID: "bravo"}, RequestID: "request-1", DedupeID: "dedupe-1", ChainID: "chain-1", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: payload}
	// A different sender spending the reserved credit must be rejected fail-closed.
	if err := rogue.tell(ctx, target.pid, task); err != nil {
		t.Fatal(err)
	}
	rejected, ok := rogue.waitFor("accepted", time.Second).(*application.ActorTaskAccepted)
	if !ok {
		t.Fatal("rogue sender never received an acceptance verdict")
	}
	if rejected.Accepted || rejected.Reason != "task credit sender identity rejected" {
		t.Fatalf("forged task origin was not rejected fail-closed: %#v", rejected)
	}
	// The GoAkt NoSender sentinel must be ignored without consuming the
	// reservation, so the reserved sender can still spend its own credit.
	if err := target.system.NoSender().Tell(ctx, target.pid, task); err != nil {
		t.Fatal(err)
	}
	// The reserved sender still spends the credit successfully.
	if err := source.tell(ctx, target.pid, task); err != nil {
		t.Fatal(err)
	}
	accepted, ok := source.waitFor("accepted", time.Second).(*application.ActorTaskAccepted)
	if !ok || !accepted.Accepted {
		t.Fatalf("reserved sender could not spend its own credit: %#v", accepted)
	}
	if deliveries := target.poll().Deliveries; len(deliveries) != 1 || deliveries[0].Kind != application.BridgeDeliveryNotification {
		t.Fatalf("reserved task did not produce a notification delivery: %#v", deliveries)
	}
}

func TestTaskCreditAndTaskRequestsRejectNoSenderSentinel(t *testing.T) {
	target := newBridgeHarness(t, "task-origin-nosender", "bravo", "alpha")
	ctx := context.Background()
	payload := []byte("task payload")
	digest := sha256.Sum256(payload)
	if _, err := target.system.NoSender().Ask(ctx, target.pid, &application.RequestTaskCredit{TaskID: "bravo-nosender", RequestID: "request", DedupeID: "dedupe", ChainID: "chain", Deadline: time.Now().Add(time.Minute), PayloadDigest: digest}, 300*time.Millisecond); err == nil {
		t.Fatal("NoSender sentinel was granted a task credit")
	}
	if _, err := target.system.NoSender().Ask(ctx, target.pid, &application.ActorTask{Credit: application.TaskCredit{TaskID: "bravo-nosender", CreditID: "forged", PayloadDigest: digest}, SourcePeer: application.CommunicationPeer{StableID: "alpha"}, RequestID: "request", DedupeID: "dedupe", ChainID: "chain", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: payload}, 300*time.Millisecond); err == nil {
		t.Fatal("NoSender sentinel task produced an acknowledgement")
	}
}

// The source starts at 21 to model an explicit daemon-state reset while a
// connected client retains its monotonic allocator. A fresh durable namespace
// may adopt any positive first sequence; every later admission is dense.

func TestSourceMutationReceiptsFencePendingAcceptedTerminalAndLegacyHistory(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("source-mutation-receipts")
	if err != nil {
		t.Fatal(err)
	}
	if err = system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = system.Stop(ctx) })
	target := spawnTaskPeer(t, ctx, system, "receipt-target")
	source, err := system.Spawn(ctx, "receipt-source", actors.NewAgentActor(&application.RegisterAgent{AgentID: "client:pm", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "client:pm"}, HostedPiRuntime: application.InactiveHostedPiRuntimeBinding(), AllowedCapability: []string{"send", "ask"}, Retention: "bounded", Recovery: "terminal-reattach"}))
	if err != nil {
		t.Fatal(err)
	}
	send := func(requestID, dedupeID, chainID, targetID, capability string, sequence uint64, mode application.BridgeMessageMode, payload string) application.BridgeIntentResult {
		receipt := make(chan application.BridgeIntentResult, 1)
		if err := system.NoSender().Tell(ctx, source, &application.SendActorTask{TargetPID: target.pid, TargetPeer: application.CommunicationPeer{StableID: targetID}, RequestID: requestID, DedupeID: dedupeID, ChainID: chainID, RequiredCapability: capability, SourceMutationSequence: sequence, Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: mode, Payload: []byte(payload), Receipt: receipt}); err != nil {
			t.Fatal(err)
		}
		select {
		case result := <-receipt:
			return result
		case <-time.After(time.Second):
			t.Fatalf("receipt missing for %s", requestID)
		}
		return application.BridgeIntentResult{}
	}
	assertStored := func(result application.BridgeIntentResult) {
		if !result.Accepted || result.Reason != "stored_pending_credit" {
			t.Fatalf("expected stored pending credit, got %#v", result)
		}
	}
	assertCollision := func(label string, result application.BridgeIntentResult) {
		if result.Accepted || result.Reason != "source mutation sequence collision" {
			t.Fatalf("%s did not fail closed: %#v", label, result)
		}
	}
	assertStored(send("request", "dedupe", "chain", "target-agent", "send", 1, application.BridgeMessageTell, "payload"))
	assertStored(send("request", "dedupe", "chain", "target-agent", "send", 1, application.BridgeMessageTell, "payload"))
	assertCollision("payload", send("request", "dedupe", "chain", "target-agent", "send", 1, application.BridgeMessageTell, "changed"))
	assertCollision("dedupe", send("request", "other-dedupe", "chain", "target-agent", "send", 1, application.BridgeMessageTell, "payload"))
	assertCollision("chain", send("request", "dedupe", "other-chain", "target-agent", "send", 1, application.BridgeMessageTell, "payload"))
	assertCollision("target", send("request", "dedupe", "chain", "other-target", "send", 1, application.BridgeMessageTell, "payload"))
	assertCollision("mode", send("request", "dedupe", "chain", "target-agent", "ask", 1, application.BridgeMessageAsk, "payload"))
	assertCollision("capability", send("request", "dedupe", "chain", "target-agent", "ask", 1, application.BridgeMessageTell, "payload"))
	if err := target.tell(ctx, source, &application.ActorTaskAccepted{TaskID: "client:pm:dedupe:chain:1", TargetAgentID: "target-agent", Accepted: true}); err != nil {
		t.Fatal(err)
	}
	assertStored(send("request", "dedupe", "chain", "target-agent", "send", 1, application.BridgeMessageTell, "payload"))
	completed := application.ActorTaskCompleted{CompletionKey: "completion", OriginalRequestID: "request", DedupeID: "dedupe", ChainID: "chain", SourceMutationSequence: 1, Terminal: application.BridgeIntentResult{Accepted: true, Completed: true, Result: []byte("done")}, Source: application.CommunicationPeer{StableID: "client:pm"}, Target: application.CommunicationPeer{StableID: "target-agent"}, Kind: application.BridgeDeliveryNotification}
	if err := system.NoSender().Tell(ctx, source, &completed); err != nil {
		t.Fatal(err)
	}
	terminal := send("request", "dedupe", "chain", "target-agent", "send", 1, application.BridgeMessageTell, "payload")
	if !terminal.Accepted || !terminal.Completed || string(terminal.Result) != "done" {
		t.Fatalf("terminal receipt not replayed: %#v", terminal)
	}
	assertCollision("terminal payload", send("request", "dedupe", "chain", "target-agent", "send", 1, application.BridgeMessageTell, "changed"))

	restartDigest := sha256.Sum256([]byte("restart payload"))
	restartFingerprint := application.SourceMutationFingerprint{RequestID: "request", DedupeID: "dedupe", ChainID: "chain", SourceMutationSequence: 1, TargetStableID: "target-agent", RequiredCapability: "send", Mode: application.BridgeMessageTell, PayloadDigest: restartDigest}
	restartRecord := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "client:restart", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "client:restart"}, Binding: application.InactiveHostedPiRuntimeBinding(), AgentState: application.DurableAgentState{ActorMessageHighWater: 1, SourceMutationReceipts: []application.DurableSourceMutationReceipt{{TaskID: "client:restart:dedupe:chain:1", Fingerprint: restartFingerprint, Result: application.BridgeIntentResult{Accepted: true, Completed: true, Result: []byte("restart done")}}}}}
	restarted, err := system.Spawn(ctx, "restart-source", actors.NewAgentActor(&application.RegisterAgent{AgentID: "client:restart", AuthorityBinding: restartRecord.AuthorityBinding, HostedPiRuntime: application.InactiveHostedPiRuntimeBinding(), AllowedCapability: []string{"send"}, Retention: "bounded", Recovery: "terminal-reattach", DurableRecord: &restartRecord}))
	if err != nil {
		t.Fatal(err)
	}
	restartReceipt := make(chan application.BridgeIntentResult, 1)
	if err := system.NoSender().Tell(ctx, restarted, &application.SendActorTask{TargetPID: target.pid, TargetPeer: application.CommunicationPeer{StableID: "target-agent"}, RequestID: "request", DedupeID: "dedupe", ChainID: "chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: []byte("restart payload"), Receipt: restartReceipt}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-restartReceipt:
		if !result.Accepted || !result.Completed || string(result.Result) != "restart done" {
			t.Fatalf("restart receipt not replayed: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("restart receipt missing")
	}

	legacyRecord := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "client:legacy", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "client:legacy"}, Binding: application.InactiveHostedPiRuntimeBinding(), AgentState: application.DurableAgentState{ActorMessageHighWater: 1, SourceTaskHistory: []application.ActorTaskCompleted{{CompletionKey: "legacy", OriginalRequestID: "request", DedupeID: "dedupe", ChainID: "chain", SourceMutationSequence: 1, Terminal: application.BridgeIntentResult{Accepted: true, Completed: true, Result: []byte("legacy")}, Source: application.CommunicationPeer{StableID: "client:legacy"}, Target: application.CommunicationPeer{StableID: "target-agent"}, Kind: application.BridgeDeliveryNotification}}}}
	legacy, err := system.Spawn(ctx, "legacy-source", actors.NewAgentActor(&application.RegisterAgent{AgentID: "client:legacy", AuthorityBinding: legacyRecord.AuthorityBinding, HostedPiRuntime: application.InactiveHostedPiRuntimeBinding(), AllowedCapability: []string{"send"}, Retention: "bounded", Recovery: "terminal-reattach", DurableRecord: &legacyRecord}))
	if err != nil {
		t.Fatal(err)
	}
	legacyReceipt := make(chan application.BridgeIntentResult, 1)
	if err := system.NoSender().Tell(ctx, legacy, &application.SendActorTask{TargetPID: target.pid, TargetPeer: application.CommunicationPeer{StableID: "target-agent"}, RequestID: "request", DedupeID: "dedupe", ChainID: "chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: []byte("changed"), Receipt: legacyReceipt}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-legacyReceipt:
		assertCollision("legacy history without fingerprint", result)
	case <-time.After(time.Second):
		t.Fatal("legacy receipt missing")
	}
}

func TestSourceMutationReceiptCapacityPinsActiveAndEvictsTerminalOnly(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("source-mutation-receipt-capacity")
	if err != nil {
		t.Fatal(err)
	}
	if err = system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = system.Stop(ctx) })
	target := spawnTaskPeer(t, ctx, system, "capacity-target")
	receipts := make([]application.DurableSourceMutationReceipt, 0, 1024)
	for sequence := uint64(1); sequence <= 1024; sequence++ {
		payload := []byte(fmt.Sprintf("payload-%d", sequence))
		receipts = append(receipts, application.DurableSourceMutationReceipt{TaskID: fmt.Sprintf("client:capacity:dedupe-%d:chain-%d:%d", sequence, sequence, sequence), Fingerprint: application.SourceMutationFingerprint{RequestID: fmt.Sprintf("request-%d", sequence), DedupeID: fmt.Sprintf("dedupe-%d", sequence), ChainID: fmt.Sprintf("chain-%d", sequence), SourceMutationSequence: sequence, TargetStableID: "target-agent", RequiredCapability: "send", Mode: application.BridgeMessageTell, PayloadDigest: sha256.Sum256(payload)}, Result: application.BridgeIntentResult{Accepted: true, AwaitingAck: true, Reason: "stored_pending_credit"}})
	}
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "client:capacity", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "client:capacity"}, Binding: application.InactiveHostedPiRuntimeBinding(), AgentState: application.DurableAgentState{ActorMessageHighWater: 1024, SourceMutationReceipts: receipts}}
	source, err := system.Spawn(ctx, "capacity-source", actors.NewAgentActor(&application.RegisterAgent{AgentID: "client:capacity", AuthorityBinding: record.AuthorityBinding, HostedPiRuntime: application.InactiveHostedPiRuntimeBinding(), AllowedCapability: []string{"send"}, Retention: "bounded", Recovery: "terminal-reattach", DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	send := func(sequence uint64) application.BridgeIntentResult {
		receipt := make(chan application.BridgeIntentResult, 1)
		payload := []byte(fmt.Sprintf("payload-%d", sequence))
		if err := system.NoSender().Tell(ctx, source, &application.SendActorTask{TargetPID: target.pid, TargetPeer: application.CommunicationPeer{StableID: "target-agent"}, RequestID: fmt.Sprintf("request-%d", sequence), DedupeID: fmt.Sprintf("dedupe-%d", sequence), ChainID: fmt.Sprintf("chain-%d", sequence), RequiredCapability: "send", SourceMutationSequence: sequence, Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: payload, Receipt: receipt}); err != nil {
			t.Fatal(err)
		}
		select {
		case result := <-receipt:
			return result
		case <-time.After(time.Second):
			t.Fatalf("receipt missing for %d", sequence)
		}
		return application.BridgeIntentResult{}
	}
	complete := func(sequence uint64, value string) {
		completed := application.ActorTaskCompleted{CompletionKey: fmt.Sprintf("complete-%d", sequence), OriginalRequestID: fmt.Sprintf("request-%d", sequence), DedupeID: fmt.Sprintf("dedupe-%d", sequence), ChainID: fmt.Sprintf("chain-%d", sequence), SourceMutationSequence: sequence, Terminal: application.BridgeIntentResult{Accepted: true, Completed: true, Result: []byte(value)}, Source: application.CommunicationPeer{StableID: "client:capacity"}, Target: application.CommunicationPeer{StableID: "target-agent"}, Kind: application.BridgeDeliveryNotification}
		if err := system.NoSender().Tell(ctx, source, &completed); err != nil {
			t.Fatal(err)
		}
	}
	oldest := send(1)
	if !oldest.Accepted || !oldest.AwaitingAck || oldest.Reason != "stored_pending_credit" {
		t.Fatalf("oldest active receipt was not replayed at capacity: %#v", oldest)
	}
	backpressured := send(1025)
	if backpressured.Accepted || backpressured.Reason != "source mutation receipt capacity is full" {
		t.Fatalf("all-active capacity did not apply bounded backpressure before admission: %#v", backpressured)
	}
	complete(1, "done-1")
	terminal := send(1)
	if !terminal.Accepted || !terminal.Completed || string(terminal.Result) != "done-1" {
		t.Fatalf("terminal update did not replay oldest receipt: %#v", terminal)
	}
	recovered := send(1025)
	if !recovered.Accepted || recovered.Reason != "stored_pending_credit" {
		t.Fatalf("terminal receipt did not restore capacity for next admission: %#v", recovered)
	}
	stillPinned := send(2)
	if !stillPinned.Accepted || !stillPinned.AwaitingAck || stillPinned.Reason != "stored_pending_credit" {
		t.Fatalf("active receipt was evicted before terminal completion: %#v", stillPinned)
	}
	evictedTerminal := send(1)
	if evictedTerminal.Accepted || evictedTerminal.Reason != "source mutation sequence collision" {
		t.Fatalf("terminal-first eviction did not retire the completed oldest receipt: %#v", evictedTerminal)
	}
}

func TestForgedTargetOriginCannotGrantCreditRetireOutboxOrPublishCommit(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("task-origin-source", goakt.WithPubSub())
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
	if _, err := system.Spawn(ctx, "committed-probe", &committedTopicProbe{committed: committed}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-committed:
	case <-time.After(time.Second):
		t.Fatal("TargetTaskCommitted subscription not acknowledged")
	}
	source, err := system.Spawn(ctx, "task-source-agent", actors.NewAgentActor(&application.RegisterAgent{AgentID: "client:pm", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "client:pm"}, HostedPiRuntime: application.InactiveHostedPiRuntimeBinding(), AllowedCapability: []string{"send"}, Retention: "bounded", Recovery: "terminal-reattach"}))
	if err != nil {
		t.Fatal(err)
	}
	reserved := spawnTaskPeer(t, ctx, system, "reserved-target")
	rogue := spawnTaskPeer(t, ctx, system, "rogue-target")
	payload := []byte("outbox payload")
	digest := sha256.Sum256(payload)
	receipt := make(chan application.BridgeIntentResult, 1)
	send := &application.SendActorTask{TargetPID: reserved.pid, TargetPeer: application.CommunicationPeer{StableID: "target-agent"}, RequestID: "request-1", DedupeID: "dedupe-1", ChainID: "chain-1", RequiredCapability: "send", SourceMutationSequence: 21, Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: payload, Receipt: receipt}
	if err = system.NoSender().Tell(ctx, source, send); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-receipt:
		if !result.Accepted || result.Reason != "stored_pending_credit" {
			t.Fatalf("source outbox admission failed: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("source outbox admission receipt missing")
	}
	taskID := "client:pm:dedupe-1:chain-1:21"
	credit := application.TaskCredit{TaskID: taskID, CreditID: "credit-1", TargetEpoch: 1, ExpiresAt: time.Now().Add(time.Minute), PayloadDigest: digest}
	// A rogue agent answering the credit request must not receive the task.
	if err = rogue.tell(ctx, source, &application.TaskCreditGranted{Credit: credit}); err != nil {
		t.Fatal(err)
	}
	if rogue.waitFor("task", 200*time.Millisecond) != nil {
		t.Fatal("forged credit grant handed the task payload to a rogue origin")
	}
	// A forged acceptance must not retire the outbox or publish a commit.
	if err = rogue.tell(ctx, source, &application.ActorTaskAccepted{TaskID: taskID, CreditID: "credit-1", TargetAgentID: "target-agent", Accepted: true}); err != nil {
		t.Fatal(err)
	}
	select {
	case message := <-committed:
		if message != nil {
			t.Fatalf("forged acceptance published a commit: %#v", message)
		}
	case <-time.After(200 * time.Millisecond):
	}
	// The reserved target still drives the full credit->task->commit sequence.
	if err = reserved.tell(ctx, source, &application.TaskCreditGranted{Credit: credit}); err != nil {
		t.Fatal(err)
	}
	if reserved.waitFor("task", time.Second) == nil {
		t.Fatal("reserved target never received the actor task")
	}
	if err = reserved.tell(ctx, source, &application.ActorTaskAccepted{TaskID: taskID, CreditID: "credit-1", TargetAgentID: "target-agent", Accepted: true}); err != nil {
		t.Fatal(err)
	}
	select {
	case message := <-committed:
		if message == nil || message.TaskID != taskID || message.TargetAgentID != "target-agent" {
			t.Fatalf("reserved acceptance did not publish the expected commit: %#v", message)
		}
	case <-time.After(time.Second):
		t.Fatal("reserved acceptance commit publication missing")
	}
}

// TestActorRefPathFieldsMustMatchReservedTargetRef proves sender validation
// compares the full durable address (host, port, and name) against the
// reserved ActorRef, not only its canonical address string: a cross-node or
// renamed actor whose ref merely reuses the reserved address is rejected
// fail-closed, while the exact reserved target still drives the flow.
func TestActorRefPathFieldsMustMatchReservedTargetRef(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("task-origin-path")
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
	reserved := spawnTaskPeer(t, ctx, system, "spoof-reserved")
	rogue := spawnTaskPeer(t, ctx, system, "spoof-rogue")
	host, port := system.Host(), system.Port()
	payload := []byte("path spoof payload")
	digest := sha256.Sum256(payload)
	ref := func(name string, host string, port int, address string) application.DurableActorRef {
		return application.DurableActorRef{AgentID: "target-agent", Host: host, Port: port, Name: name, Address: address}
	}
	item := func(taskID, dedupe, chain string, sequence uint64, targetRef application.DurableActorRef) application.DurableActorTaskOutboxItem {
		return application.DurableActorTaskOutboxItem{TaskID: taskID, Target: application.CommunicationPeer{StableID: "target-agent"}, TargetRef: targetRef, RequestID: "request-" + dedupe, DedupeID: dedupe, ChainID: chain, RequiredCapability: "send", SourceMutationSequence: sequence, Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: payload, PayloadDigest: digest, State: "pending_credit"}
	}
	// The name-spoofed ref carries the rogue's own address, so an address-only
	// comparison would accept the rogue as the reserved target.
	nameSpoofed := item("client:pm:name-spoof:chain-a:1", "name-spoof", "chain-a", 1, ref("spoof-reserved", host, port, rogue.pid.ID()))
	// The port- and host-spoofed refs carry the reserved target's own address
	// but claim a different node endpoint.
	portSpoofed := item("client:pm:port-spoof:chain-b:2", "port-spoof", "chain-b", 2, ref("spoof-reserved", host, port+1, reserved.pid.ID()))
	hostSpoofed := item("client:pm:host-spoof:chain-c:3", "host-spoof", "chain-c", 3, ref("spoof-reserved", "foreign-node", port, reserved.pid.ID()))
	exact := item("client:pm:exact:chain-d:4", "exact", "chain-d", 4, actorRefOf("target-agent", reserved.pid))
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "client:pm", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "client:pm"}, Binding: application.InactiveHostedPiRuntimeBinding(), AgentState: application.DurableAgentState{SourceOutbox: []application.DurableActorTaskOutboxItem{nameSpoofed, portSpoofed, hostSpoofed, exact}}}
	source, err := system.Spawn(ctx, "spoof-source-agent", actors.NewAgentActor(&application.RegisterAgent{AgentID: "client:pm", AuthorityBinding: record.AuthorityBinding, HostedPiRuntime: record.Binding, AllowedCapability: []string{"send"}, Retention: "bounded", Recovery: "terminal-reattach", DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	grant := func(taskID string) *application.TaskCreditGranted {
		return &application.TaskCreditGranted{Credit: application.TaskCredit{TaskID: taskID, CreditID: "credit-" + taskID, TargetEpoch: 1, ExpiresAt: time.Now().Add(time.Minute), PayloadDigest: digest}}
	}
	// The rogue must not be handed the task even though it owns the spoofed
	// ref's exact address string.
	if err = rogue.tell(ctx, source, grant(nameSpoofed.TaskID)); err != nil {
		t.Fatal(err)
	}
	if rogue.waitFor("task", 250*time.Millisecond) != nil {
		t.Fatal("name-spoofed target ref handed the task to a rogue sender")
	}
	// The reserved target itself must be rejected while the ref claims a
	// different node endpoint (port or host).
	if err = reserved.tell(ctx, source, grant(portSpoofed.TaskID)); err != nil {
		t.Fatal(err)
	}
	if err = reserved.tell(ctx, source, grant(hostSpoofed.TaskID)); err != nil {
		t.Fatal(err)
	}
	if reserved.waitFor("task", 250*time.Millisecond) != nil {
		t.Fatal("endpoint-spoofed target ref handed the task to the reserved sender")
	}
	// The exact reserved ref still drives the credit flow end to end.
	if err = reserved.tell(ctx, source, grant(exact.TaskID)); err != nil {
		t.Fatal(err)
	}
	task, ok := reserved.waitFor("task", time.Second).(*application.ActorTask)
	if !ok {
		t.Fatal("exact reserved target ref never received the actor task")
	}
	if task.Credit.TaskID != exact.TaskID || string(task.Payload) != string(payload) {
		t.Fatalf("exact reserved ref handed the wrong task: %#v", task)
	}
}
