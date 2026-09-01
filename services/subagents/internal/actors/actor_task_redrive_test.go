package actors_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
)

type creditProbe struct {
	t        *testing.T
	pid      *goakt.PID
	mu       chan struct{}
	received chan any
}

func (*creditProbe) PreStart(*goakt.Context) error { return nil }
func (*creditProbe) PostStop(*goakt.Context) error { return nil }
func (p *creditProbe) Receive(ctx *goakt.ReceiveContext) {
	select {
	case p.received <- ctx.Message():
	default:
	}
}

func (p *creditProbe) waitFor(kind string, timeout time.Duration) any {
	deadline := time.After(timeout)
	for {
		select {
		case message := <-p.received:
			switch value := message.(type) {
			case *application.RequestTaskCredit:
				if kind == "credit" {
					return value
				}
			case *application.ActorTaskCompleted:
				if kind == "completed" {
					return value
				}
			}
		case <-deadline:
			return nil
		}
	}
}

func spawnCreditProbe(t *testing.T, ctx context.Context, system goakt.ActorSystem, name string) *creditProbe {
	t.Helper()
	probe := &creditProbe{t: t, received: make(chan any, 32)}
	pid, err := system.Spawn(ctx, name, probe)
	if err != nil {
		t.Fatal(err)
	}
	probe.pid = pid
	return probe
}

func actorRefOf(agentID string, pid *goakt.PID) application.DurableActorRef {
	ref := application.DurableActorRef{AgentID: agentID}
	if path := pid.Path(); path != nil {
		ref.Host, ref.Port, ref.Name = path.Host(), path.Port(), path.Name()
	}
	ref.Address = pid.ID()
	return ref
}

func stableAgentActorName(agentID string) string {
	digest := sha256.Sum256([]byte(agentID))
	return "agent-" + hex.EncodeToString(digest[:8])
}

// A terminal completion whose cross-actor Tell failed is retained durably and
// redriven after the original source actor comes back; the completion is
// delivered exactly once despite repeated redrives.
func TestCompletionTellPendingRedrivesAfterSourceReturns(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("completion-redrive")
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
	// Spawn and stop the source actor so its durable address is known but
	// initially unresolvable: early redrive attempts must fail bounded.
	source := spawnCreditProbe(t, ctx, system, "late-source")
	sourceRef := actorRefOf("client:pm", source.pid)
	if err := source.pid.Stop(ctx, source.pid); err != nil {
		t.Fatal(err)
	}
	store := &cursorAckStore{notify: make(chan struct{}, 8)}
	writer, err := system.Spawn(ctx, "completion-writer", &actors.HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.State, binding.BridgeReady, binding.RuntimeID, binding.Incarnation = application.HostedPiRuntimeReady, true, "runtime-bravo", 1
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "bravo", Binding: binding, AgentState: application.DurableAgentState{BridgeReady: true, CompletionTellPending: []application.DurablePendingCompletion{{CompletionKey: "bravo:7:client:pm:request:dedupe:chain:1", Source: sourceRef, Completed: application.ActorTaskCompleted{CompletionKey: "bravo:7:client:pm:request:dedupe:chain:1", OriginalRequestID: "request", DedupeID: "dedupe", ChainID: "chain", SourceMutationSequence: 1, Terminal: application.BridgeIntentResult{Accepted: true, Completed: true, Result: []byte("late answer")}, Kind: application.BridgeDeliveryPrompt}}}}}
	if _, err := system.Spawn(ctx, "completion-target", actors.NewAgentActor(&application.RegisterAgent{AgentID: "bravo", HostedPiRuntime: binding, AllowedCapability: []string{"hosted_bridge"}, PersistencePID: writer, DurableRecord: &record})); err != nil {
		t.Fatal(err)
	}
	time.Sleep(150 * time.Millisecond)
	// The source actor returns with the same address: the next redrive must
	// deliver the retained completion exactly once.
	returned := spawnCreditProbe(t, ctx, system, "late-source")
	defer returned.pid.Stop(ctx, nil)
	completed, ok := returned.waitFor("completed", 3*time.Second).(*application.ActorTaskCompleted)
	if !ok {
		t.Fatal("retained completion was never redriven to the returned source")
	}
	if completed.CompletionKey != "bravo:7:client:pm:request:dedupe:chain:1" || string(completed.Terminal.Result) != "late answer" {
		t.Fatalf("redriven completion carried the wrong terminal: %#v", completed)
	}
	select {
	case extra := <-returned.received:
		if done, isDone := extra.(*application.ActorTaskCompleted); isDone && done.CompletionKey == completed.CompletionKey {
			t.Fatal("redriven completion was delivered more than once")
		}
	case <-time.After(150 * time.Millisecond):
	}
}

// Restart reload re-drives pending source outbox entries: credit requests go
// back out through the durable logical target route, and entries past their
// deadline fail closed with a retained terminal.
func TestExpiredActorTaskSendsOneFailureCompletionAndRejectsLateAck(t *testing.T) {
	b := newBridgeHarness(t, "actor-task-expiry-completion", "bravo", "bravo-host")
	ctx := context.Background()
	sourceRegistration := &application.RegisterAgent{AgentID: "alpha", HostedPiRuntime: application.InactiveHostedPiRuntimeBinding(), AllowedCapability: []string{"send", "ask", "prompt"}, Retention: "bounded", Recovery: "terminal-reattach"}
	source, err := b.system.Spawn(ctx, "agent-alpha", actors.NewAgentActor(sourceRegistration))
	if err != nil {
		t.Fatal(err)
	}
	receipt := make(chan application.BridgeIntentResult, 1)
	deadline := time.Now().Add(80 * time.Millisecond)
	if err := b.system.NoSender().Tell(ctx, source, &application.SendActorTask{TargetPID: b.pid, TargetPeer: application.CommunicationPeer{StableID: "bravo"}, RequestID: "expire-request", RequiredCapability: "send", DedupeID: "expire-dedupe", ChainID: "expire-chain", Deadline: deadline, HopLimit: 8, SourceMutationSequence: 1, Mode: application.BridgeMessageTell, Payload: []byte("expire before ack"), Receipt: receipt}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-receipt:
		if !result.Accepted {
			t.Fatalf("actor task was not accepted before expiry: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("actor task admission did not complete")
	}
	var delivery application.BridgeDelivery
	pollDeadline := time.Now().Add(time.Second)
	for time.Now().Before(pollDeadline) {
		deliveries := b.poll().Deliveries
		if len(deliveries) == 1 {
			delivery = deliveries[0]
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if delivery.CompletionKey == "" {
		t.Fatal("accepted actor task never reached the target bridge")
	}
	var completions []application.ActorTaskCompleted
	completionDeadline := time.Now().Add(time.Second)
	for time.Now().Before(completionDeadline) {
		drained := make(chan []application.ActorTaskCompleted, 1)
		if err := b.system.NoSender().Tell(ctx, source, &application.DrainReceivedTaskCompletions{Result: drained}); err != nil {
			t.Fatal(err)
		}
		completions = <-drained
		if len(completions) > 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if len(completions) != 1 {
		t.Fatalf("expired task yielded %d source completions, want exactly one: %#v", len(completions), completions)
	}
	failure := completions[0]
	if failure.CompletionKey != delivery.CompletionKey || failure.Terminal.Completed || failure.Terminal.Reason != "delivery acknowledgement deadline expired" {
		t.Fatalf("expired task completion carried wrong terminal: %#v", failure)
	}
	late := b.ack(delivery, "late real ack")
	if late.Accepted || late.Reason == "" {
		t.Fatalf("late real acknowledgement after terminal failure was not rejected: %#v", late)
	}
	drained := make(chan []application.ActorTaskCompleted, 1)
	if err := b.system.NoSender().Tell(ctx, source, &application.DrainReceivedTaskCompletions{Result: drained}); err != nil {
		t.Fatal(err)
	}
	afterLate := <-drained
	if len(afterLate) != 1 || afterLate[0].CompletionKey != failure.CompletionKey || afterLate[0].Terminal.Reason != failure.Terminal.Reason || string(afterLate[0].Terminal.Result) != "" {
		t.Fatalf("late acknowledgement overwrote terminal failure: %#v", afterLate)
	}
}

// TestOutboxRedriveReRequestsCreditAfterRepeatedLoss proves the bounded
// redrive loop keeps ticking: a pending item whose credit requests keep
// getting lost (the target never grants) re-requests credit on every backoff
// tick instead of stopping after one retry.
func TestOutboxRedriveReRequestsCreditAfterRepeatedLoss(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("outbox-recredit")
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
	// The target probe never grants credit: every request is lost.
	target := spawnCreditProbe(t, ctx, system, "lost-credit-target")
	defer target.pid.Stop(ctx, nil)
	store := &cursorAckStore{notify: make(chan struct{}, 8)}
	writer, err := system.Spawn(ctx, "lost-credit-writer", &actors.HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	binding := application.InactiveHostedPiRuntimeBinding()
	lost := application.DurableActorTaskOutboxItem{TaskID: "client:pm:lost:chain:1", Target: application.CommunicationPeer{StableID: "lost-credit-target"}, TargetRef: actorRefOf("lost-credit-target", target.pid), RequestID: "request-lost", DedupeID: "lost", ChainID: "chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 4, Mode: application.BridgeMessageTell, Payload: []byte("lost payload"), State: "pending_credit"}
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "client:pm", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "client:pm"}, Binding: binding, AgentState: application.DurableAgentState{SourceOutbox: []application.DurableActorTaskOutboxItem{lost}}}
	source, err := system.Spawn(ctx, "lost-credit-source", actors.NewAgentActor(&application.RegisterAgent{AgentID: "client:pm", AuthorityBinding: record.AuthorityBinding, HostedPiRuntime: binding, AllowedCapability: []string{"send"}, Retention: "bounded", Recovery: "terminal-reattach", PersistencePID: writer, DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	requests := 0
	deadline := time.After(2 * time.Second)
	for requests < 3 {
		select {
		case message := <-target.received:
			if _, ok := message.(*application.RequestTaskCredit); ok {
				requests++
			}
		case <-deadline:
			t.Fatalf("repeated loss re-requested credit only %d times, want at least 3", requests)
		}
	}
	// The item is still pending credit (not terminal): an exact replay must
	// report the retained pending admission.
	receipt := make(chan application.BridgeIntentResult, 1)
	if err = system.NoSender().Tell(ctx, source, &application.SendActorTask{TargetPID: target.pid, TargetPeer: application.CommunicationPeer{StableID: "lost-credit-target"}, RequestID: "request-lost", DedupeID: "lost", ChainID: "chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 4, Mode: application.BridgeMessageTell, Payload: []byte("lost payload"), Receipt: receipt}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-receipt:
		if !result.Accepted || result.Reason != "stored_pending_credit" {
			t.Fatalf("repeatedly lost item left the pending-credit state: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("replay receipt missing")
	}
}

// A durable outbox entry can outlive the hosted runtime PID it was admitted
// against. Runtime children are incarnation-scoped, so redrive must route by
// the logical AgentID to the retained owner AgentActor and accept that owner's
// grant; comparing the grant to the stale child path leaves the item in
// pending_credit forever even though the replacement bridge is ready.
func TestOutboxPendingCreditRoutesStaleRuntimeRefThroughReplacementOwner(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("outbox-runtime-bounce", goakt.WithPubSub(), goakt.WithMessageRetention(time.Minute))
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

	oldRuntime, err := system.Spawn(ctx, "hosted-pi-runtime-old-incarnation", &inertRuntimeActor{})
	if err != nil {
		t.Fatal(err)
	}
	staleTarget := actorRefOf("bravo", oldRuntime)
	if err = oldRuntime.Stop(ctx, oldRuntime); err != nil {
		t.Fatal(err)
	}

	binding := application.InactiveHostedPiRuntimeBinding()
	binding.State, binding.RuntimeID, binding.Incarnation, binding.BridgeReady = application.HostedPiRuntimeReady, "runtime-bravo-new", 2, true
	targetRegistration := &application.RegisterAgent{AgentID: "bravo", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: binding.RuntimeID}, HostedPiRuntime: binding, AllowedCapability: []string{"hosted_bridge", "send"}, Retention: "explicit", Recovery: "owned"}
	target, err := system.Spawn(ctx, stableAgentActorName("bravo"), actors.NewAgentActor(targetRegistration))
	if err != nil {
		t.Fatal(err)
	}
	newRuntime, err := system.Spawn(ctx, "hosted-pi-runtime-new-incarnation", &inertRuntimeActor{})
	if err != nil {
		t.Fatal(err)
	}
	if err = system.NoSender().Tell(ctx, target, &application.BindHostedPiRuntimeActor{PID: newRuntime}); err != nil {
		t.Fatal(err)
	}

	attachedValue, err := system.NoSender().Ask(ctx, target, &application.AttachAgent{SessionID: "session-bravo", GenerationID: "generation-bravo", Principal: "hosted:bravo", AgentID: "bravo", RequestedCapabilities: targetRegistration.AllowedCapability, IssuedHandle: "handle-bravo"}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	attached := attachedValue.(*application.AttachResult)
	if !attached.Completed {
		t.Fatalf("replacement owner attach failed: %#v", attached)
	}
	connectedValue, err := system.NoSender().Ask(ctx, target, &application.BridgeConnect{SessionID: "session-bravo", GenerationID: "generation-bravo", Principal: "hosted:bravo", AgentID: "bravo", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: binding.RuntimeID, Incarnation: binding.Incarnation, PiSessionID: "pi-bravo-new"}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if connected := connectedValue.(*application.BridgeResult); !connected.Accepted {
		t.Fatalf("replacement owner bridge connect failed: %#v", connected)
	}

	payload := []byte("deliver after runtime bounce")
	digest := sha256.Sum256(payload)
	item := application.DurableActorTaskOutboxItem{TaskID: "alpha:bounce:chain:1", Target: application.CommunicationPeer{StableID: "bravo"}, TargetRef: staleTarget, RequestID: "request-bounce", DedupeID: "bounce", ChainID: "chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 4, Mode: application.BridgeMessageTell, Payload: payload, PayloadDigest: digest, State: "pending_credit"}
	sourceBinding := application.InactiveHostedPiRuntimeBinding()
	sourceRecord := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "alpha", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "alpha"}, Binding: sourceBinding, AgentState: application.DurableAgentState{SourceOutbox: []application.DurableActorTaskOutboxItem{item}}}
	if _, err = system.Spawn(ctx, stableAgentActorName("alpha"), actors.NewAgentActor(&application.RegisterAgent{AgentID: "alpha", AuthorityBinding: sourceRecord.AuthorityBinding, HostedPiRuntime: sourceBinding, AllowedCapability: []string{"send"}, Retention: "bounded", Recovery: "terminal-reattach", DurableRecord: &sourceRecord})); err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		polledValue, askErr := system.NoSender().Ask(ctx, target, &application.PollBridge{SessionID: "session-bravo", GenerationID: "generation-bravo", Principal: "hosted:bravo", Handle: attached.Handle, Fence: attached.Fence, MaxItems: 64}, time.Second)
		if askErr != nil {
			t.Fatal(askErr)
		}
		deliveries := polledValue.(*application.BridgePollResult).Deliveries
		if len(deliveries) == 1 {
			if deliveries[0].SourceAgentID != "alpha" || string(deliveries[0].Payload) != string(payload) {
				t.Fatalf("replacement owner queued the wrong delivery: %#v", deliveries[0])
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("pending credit never granted through the replacement owner after runtime bounce")
}

func TestOutboxRestartRedriveReRequestsCreditAndFailsExpired(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("outbox-redrive")
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
	target := spawnCreditProbe(t, ctx, system, "outbox-target")
	defer target.pid.Stop(ctx, nil)
	store := &cursorAckStore{notify: make(chan struct{}, 8)}
	writer, err := system.Spawn(ctx, "outbox-writer", &actors.HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	binding := application.InactiveHostedPiRuntimeBinding()
	expired := application.DurableActorTaskOutboxItem{TaskID: "client:pm:expired:chain:1", Target: application.CommunicationPeer{StableID: "outbox-target"}, TargetRef: actorRefOf("outbox-target", target.pid), RequestID: "request-expired", DedupeID: "expired", ChainID: "chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(-time.Minute), HopLimit: 4, Mode: application.BridgeMessageTell, Payload: []byte("expired payload"), State: "pending_credit"}
	live := application.DurableActorTaskOutboxItem{TaskID: "client:pm:live:chain:2", Target: application.CommunicationPeer{StableID: "outbox-target"}, TargetRef: actorRefOf("outbox-target", target.pid), RequestID: "request-live", DedupeID: "live", ChainID: "chain", RequiredCapability: "send", SourceMutationSequence: 2, Deadline: time.Now().Add(time.Minute), HopLimit: 4, Mode: application.BridgeMessageTell, Payload: []byte("live payload"), State: "pending_credit"}
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "client:pm", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "client:pm"}, Binding: binding, AgentState: application.DurableAgentState{SourceOutbox: []application.DurableActorTaskOutboxItem{expired, live}}}
	source, err := system.Spawn(ctx, "outbox-source", actors.NewAgentActor(&application.RegisterAgent{AgentID: "client:pm", AuthorityBinding: record.AuthorityBinding, HostedPiRuntime: binding, AllowedCapability: []string{"send"}, Retention: "bounded", Recovery: "terminal-reattach", PersistencePID: writer, DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	credit, ok := target.waitFor("credit", 3*time.Second).(*application.RequestTaskCredit)
	if !ok {
		t.Fatal("restart reload did not re-drive the pending outbox credit request")
	}
	if credit.TaskID != "client:pm:live:chain:2" {
		t.Fatalf("redriven credit request carried the wrong task: %#v", credit)
	}
	// The expired entry must fail closed with a retained terminal result. The
	// probe retries transient busy windows while the redrive retirement
	// persists.
	deadline := time.Now().Add(3 * time.Second)
	for {
		receipt := make(chan application.BridgeIntentResult, 1)
		if err = system.NoSender().Tell(ctx, source, &application.SendActorTask{TargetPID: target.pid, TargetPeer: application.CommunicationPeer{StableID: "outbox-target"}, RequestID: "request-expired", DedupeID: "expired", ChainID: "chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 4, Mode: application.BridgeMessageTell, Payload: []byte("expired payload"), Receipt: receipt}); err != nil {
			t.Fatal(err)
		}
		select {
		case result := <-receipt:
			if !result.Accepted && result.Reason == "durable persistence is busy" && time.Now().Before(deadline) {
				time.Sleep(25 * time.Millisecond)
				continue
			}
			if result.Accepted || result.Reason != "actor task deadline expired before delivery" {
				t.Fatalf("expired outbox entry did not fail closed with the retained terminal: %#v", result)
			}
		case <-time.After(deadline.Sub(time.Now())):
			t.Fatal("expired outbox entry never produced a retained terminal")
		}
		return
	}
}
