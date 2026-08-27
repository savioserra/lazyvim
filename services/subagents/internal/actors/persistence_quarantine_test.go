package actors

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

func TestDurableFailureQuarantinesThroughPersistenceSupervisor(t *testing.T) {
	ctx := context.Background()
	system, err := actor.NewActorSystem("durable-quarantine")
	if err != nil {
		t.Fatal(err)
	}
	if err := system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = system.Stop(ctx) })
	store := &blockingStore{started: make(chan application.DurableHostedRecord, 2), release: make(chan error, 2)}
	writer, err := system.Spawn(ctx, "writer", &HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	quarantine, err := system.Spawn(ctx, "quarantine", &PersistenceSupervisor{})
	if err != nil {
		t.Fatal(err)
	}
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.State = application.HostedPiRuntimeReady
	binding.BridgeReady = true
	binding.RuntimeID = "runtime"
	binding.Incarnation = 1
	state := application.DurableAgentState{Fence: 1, BridgeFence: 1, BridgeReady: true, BridgeDeclaredReady: true, BridgeSession: "session", BridgeGeneration: "generation", BridgePrincipal: "hosted:source", BridgeHandle: "handle", BridgePiSession: "pi", Attachments: []application.DurableAttachment{{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: "handle", Fence: 1, Capabilities: []string{"send", "hosted_bridge"}}}}
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "target", Binding: binding, AgentState: state}
	registration := &application.RegisterAgent{AgentID: "target", HostedPiRuntime: binding, AllowedCapability: []string{"send", "hosted_bridge"}, PersistencePID: writer, PersistenceSupervisor: quarantine, DurableRecord: &record}
	pid, err := system.Spawn(ctx, "agent", NewAgentActor(registration))
	if err != nil {
		t.Fatal(err)
	}
	receipt := make(chan application.BridgeIntentResult, 1)
	intent := &application.BridgeIntent{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: "handle", Fence: 1, SourceAgentID: "source", TargetAgentID: "target", RequestID: "request", RequiredCapability: "send", DedupeID: "dedupe", ChainID: "chain", Deadline: time.Now().Add(time.Minute), HopLimit: 2, SourceMutationSequence: 1, Mode: application.BridgeMessageTell, Payload: []byte("payload"), Receipt: receipt}
	if err := system.NoSender().Tell(ctx, pid, intent); err != nil {
		t.Fatal(err)
	}
	<-store.started
	store.release <- errors.New("fsync failed")
	<-store.started
	store.release <- nil
	select {
	case result := <-receipt:
		if result.Accepted || result.Reason == "" {
			t.Fatalf("failed durable mutation accepted: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("receipt timed out")
	}
	value, err := system.NoSender().Ask(ctx, quarantine, &application.DurableQuarantineStatus{}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	status := value.(*application.DurableQuarantineState)
	if !status.FailClosed || status.Items["target"] == "" {
		t.Fatalf("quarantine not visible: %#v", status)
	}
}
