package actors_test

import (
	"context"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
)

func TestActorAskReturnsRegularTerminalModelAnswerToSource(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("regular-terminal-delivery", goakt.WithPubSub())
	if err != nil {
		t.Fatal(err)
	}
	if err := system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = system.Stop(ctx) })

	store := &cursorAckStore{notify: make(chan struct{}, 16)}
	writer, err := system.Spawn(ctx, "regular-terminal-writer", &actors.HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	sourceBinding := application.InactiveHostedPiRuntimeBinding()
	sourceBinding.State, sourceBinding.BridgeReady, sourceBinding.RuntimeID, sourceBinding.Incarnation = application.HostedPiRuntimeReady, true, "runtime-source", 1
	sourceRecord := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "source-agent", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "source-agent"}, Binding: sourceBinding}
	source, err := system.Spawn(ctx, "regular-terminal-source", actors.NewAgentActor(&application.RegisterAgent{AgentID: "source-agent", AuthorityBinding: sourceRecord.AuthorityBinding, HostedPiRuntime: sourceBinding, AllowedCapability: []string{"send", "observe"}, Retention: "bounded", Recovery: "terminal-reattach", PersistencePID: writer, DurableRecord: &sourceRecord}))
	if err != nil {
		t.Fatal(err)
	}
	targetRecord := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "client:terminal", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "client:terminal"}, Binding: application.InactiveHostedPiRuntimeBinding()}
	target, err := system.Spawn(ctx, "regular-terminal-target", actors.NewAgentActor(&application.RegisterAgent{AgentID: "client:terminal", Role: "TERMINAL PI", DisplayName: "TERMINAL PI", AuthorityBinding: targetRecord.AuthorityBinding, HostedPiRuntime: targetRecord.Binding, AllowedCapability: []string{"observe", "send", "ask", "prompt"}, Retention: "bounded", Recovery: "terminal-reattach", PersistencePID: writer, DurableRecord: &targetRecord}))
	if err != nil {
		t.Fatal(err)
	}

	attached := make(chan application.AttachResult, 1)
	if err := system.NoSender().Tell(ctx, target, &application.AttachAgent{SessionID: "terminal-session", GenerationID: "terminal-generation", Principal: "client:terminal", AgentID: "client:terminal", RequestedCapabilities: []string{"observe", "send", "ask", "prompt"}, IssuedHandle: "terminal-handle", Result: attached}); err != nil {
		t.Fatal(err)
	}
	var fence application.AttachResult
	select {
	case fence = <-attached:
	case <-time.After(time.Second):
		t.Fatal("terminal self attach timed out")
	}
	if !fence.Completed {
		t.Fatalf("terminal attach rejected: %#v", fence)
	}

	receipt := make(chan application.BridgeIntentResult, 1)
	if err := system.NoSender().Tell(ctx, source, &application.SendActorTask{TargetPID: target, TargetPeer: application.CommunicationPeer{StableID: "client:terminal", DisplayName: "PROJECT MANAGER", Role: "PROJECT MANAGER"}, RequestID: "regular-request", RequiredCapability: "send", DedupeID: "regular-dedupe", ChainID: "regular-chain", Deadline: time.Now().Add(5 * time.Second), HopLimit: 8, SourceMutationSequence: 1, Mode: application.BridgeMessageAsk, Payload: []byte("terminal delivery"), Receipt: receipt}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-receipt:
		if !result.Accepted || !result.AwaitingAck {
			t.Fatalf("source admission failed: %#v", result)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("source admission timed out")
	}

	var delivery application.BridgeDelivery
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		value, err := system.NoSender().Ask(ctx, target, &application.PollBridge{SessionID: "terminal-session", GenerationID: "terminal-generation", Principal: "client:terminal", Handle: fence.Handle, Fence: fence.Fence, MaxItems: 8}, time.Second)
		if err == nil {
			poll := value.(*application.BridgePollResult)
			if len(poll.Deliveries) == 1 {
				delivery = poll.Deliveries[0]
				break
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	if delivery.DeliveryBackend != "regular" || string(delivery.Payload) != "terminal delivery" {
		t.Fatalf("regular terminal delivery missing: %#v", delivery)
	}

	acked := make(chan application.BridgeDeliveryAckResult, 1)
	if err := system.NoSender().Tell(ctx, target, &application.BridgeDeliveryAck{SessionID: "terminal-session", GenerationID: "terminal-generation", Principal: "client:terminal", Handle: fence.Handle, Fence: fence.Fence, Sequence: delivery.Sequence, DedupeID: delivery.DedupeID, Delivered: true, Result: []byte("Actual model answer"), Kind: application.BridgeDeliveryKindLabel(delivery.Kind), SourceScope: delivery.SourceScope, CompletionKey: delivery.CompletionKey, Completion: acked}); err != nil {
		t.Fatal(err)
	}
	select {
	case ack := <-acked:
		if !ack.Accepted {
			t.Fatalf("regular ack rejected: %#v", ack)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("regular ack timed out")
	}

	drained := make(chan []application.ActorTaskCompleted, 1)
	if err := system.NoSender().Tell(ctx, source, &application.DrainReceivedTaskCompletions{Result: drained}); err != nil {
		t.Fatal(err)
	}
	select {
	case completed := <-drained:
		if len(completed) != 1 || !completed[0].Terminal.Completed || string(completed[0].Terminal.Result) != "Actual model answer" || completed[0].CompletionKey != delivery.CompletionKey {
			t.Fatalf("source completion missing: %#v", completed)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("source completion timed out")
	}
}
