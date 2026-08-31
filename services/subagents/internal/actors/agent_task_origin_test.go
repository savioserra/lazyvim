package actors_test

import (
	"context"
	"crypto/sha256"
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
	send := &application.SendActorTask{TargetPID: reserved.pid, TargetPeer: application.CommunicationPeer{StableID: "target-agent"}, RequestID: "request-1", DedupeID: "dedupe-1", ChainID: "chain-1", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: payload, Receipt: receipt}
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
	taskID := "client:pm:dedupe-1:chain-1:1"
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
