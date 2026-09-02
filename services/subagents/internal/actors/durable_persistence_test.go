package actors

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
	"github.com/tochemey/goakt/v4/supervisor"
)

type blockingStore struct {
	started chan application.DurableHostedRecord
	release chan error
}

func (s *blockingStore) Save(_ context.Context, r application.DurableHostedRecord) error {
	s.started <- r
	return <-s.release
}
func (*blockingStore) Remove(context.Context, string) error { return nil }

func TestDurableMutationReceiptWaitsForAsyncFsyncAndReceiveStaysNonblocking(t *testing.T) {
	ctx := context.Background()
	system, err := actor.NewActorSystem("durable-test")
	if err != nil {
		t.Fatal(err)
	}
	if err = system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	defer system.Stop(ctx)
	store := &blockingStore{started: make(chan application.DurableHostedRecord, 1), release: make(chan error, 1)}
	writer, err := system.Spawn(ctx, "writer", &HostedStateWriterActor{Store: store}, actor.WithSupervisor(supervisor.NewSupervisor(supervisor.WithAnyErrorDirective(supervisor.RestartDirective))))
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
	registration := &application.RegisterAgent{AgentID: "target", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: "runtime"}, HostedPiRuntime: binding, AllowedCapability: []string{"send", "hosted_bridge"}, PersistencePID: writer, DurableRecord: &record}
	pid, err := system.Spawn(ctx, "agent", NewAgentActor(registration))
	if err != nil {
		t.Fatal(err)
	}
	receipt := make(chan application.BridgeIntentResult, 1)
	intent := &application.BridgeIntent{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: "handle", Fence: 1, SourceAgentID: "source", TargetAgentID: "target", RequestID: "request", RequiredCapability: "send", DedupeID: "dedupe", ChainID: "chain", Deadline: time.Now().Add(time.Minute), HopLimit: 2, SourceMutationSequence: 1, Mode: application.BridgeMessageTell, Payload: []byte("operational payload"), Receipt: receipt}
	if err = system.NoSender().Tell(ctx, pid, intent); err != nil {
		t.Fatal(err)
	}
	var persisted application.DurableHostedRecord
	select {
	case persisted = <-store.started:
	case result := <-receipt:
		t.Fatalf("mutation rejected before persistence: %#v", result)
	case <-time.After(time.Second):
		t.Fatal("persistence effect did not start")
	}
	if len(persisted.AgentState.BridgeDeliveries) != 1 {
		t.Fatal("accepted delivery was not in fsync state")
	}
	select {
	case <-receipt:
		t.Fatal("mutation receipt preceded durable fsync")
	default:
	}
	poll, err := system.NoSender().Ask(ctx, pid, &application.PollBridge{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: "handle", Fence: 1}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	pollResult := poll.(*application.BridgePollResult)
	if len(pollResult.Deliveries) != 0 || pollResult.Reason == "" {
		t.Fatalf("uncommitted delivery became observable: %#v", pollResult)
	}
	value, err := system.NoSender().Ask(ctx, pid, &application.Subscribers{}, time.Second)
	if err != nil || value == nil {
		t.Fatal("Receive blocked on persistence effect")
	}
	store.release <- nil
	select {
	case result := <-receipt:
		if !result.Accepted {
			t.Fatalf("durable mutation rejected: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("durable mutation receipt missing after fsync")
	}
}

func TestBridgeLifecycleReadyReturnsTransientBusyDuringDurableMutationAndConverges(t *testing.T) {
	ctx := context.Background()
	system, err := actor.NewActorSystem("lifecycle-busy-test")
	if err != nil {
		t.Fatal(err)
	}
	if err = system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	defer system.Stop(ctx)
	store := &blockingStore{started: make(chan application.DurableHostedRecord, 1), release: make(chan error, 1)}
	writer, err := system.Spawn(ctx, "writer", &HostedStateWriterActor{Store: store}, actor.WithSupervisor(supervisor.NewSupervisor(supervisor.WithAnyErrorDirective(supervisor.RestartDirective))))
	if err != nil {
		t.Fatal(err)
	}
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.State = application.HostedPiRuntimeReady
	binding.BridgeReady = true
	binding.RuntimeID = "runtime"
	binding.Incarnation = 1
	state := application.DurableAgentState{Fence: 1, BridgeFence: 1, BridgeReady: true, BridgeDeclaredReady: true, BridgeSession: "session", BridgeGeneration: "generation", BridgePrincipal: "hosted:target", BridgeHandle: "handle", BridgePiSession: "pi", Attachments: []application.DurableAttachment{{SessionID: "session", GenerationID: "generation", Principal: "hosted:target", Handle: "handle", Fence: 1, Capabilities: []string{"send", "hosted_bridge"}}}}
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "target", Binding: binding, AgentState: state}
	registration := &application.RegisterAgent{AgentID: "target", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: "runtime"}, HostedPiRuntime: binding, AllowedCapability: []string{"send", "hosted_bridge"}, PersistencePID: writer, DurableRecord: &record}
	pid, err := system.Spawn(ctx, "agent", NewAgentActor(registration))
	if err != nil {
		t.Fatal(err)
	}
	intentReceipt := make(chan application.BridgeIntentResult, 1)
	intent := &application.BridgeIntent{SessionID: "session", GenerationID: "generation", Principal: "hosted:target", Handle: "handle", Fence: 1, SourceAgentID: "source", TargetAgentID: "target", RequestID: "request", RequiredCapability: "send", DedupeID: "dedupe", ChainID: "chain", Deadline: time.Now().Add(time.Minute), HopLimit: 2, SourceMutationSequence: 1, Mode: application.BridgeMessageTell, Payload: []byte("payload"), Receipt: intentReceipt}
	if err = system.NoSender().Tell(ctx, pid, intent); err != nil {
		t.Fatal(err)
	}
	select {
	case <-store.started:
	case result := <-intentReceipt:
		t.Fatalf("intent completed before durable busy window: %#v", result)
	case <-time.After(time.Second):
		t.Fatal("intent persistence did not start")
	}
	busy := make(chan application.BridgeResult, 1)
	ready := &application.BridgeLifecycle{SessionID: "session", GenerationID: "generation", Principal: "hosted:target", AgentID: "target", Handle: "handle", Fence: 1, RuntimeID: "runtime", Incarnation: 1, Event: application.BridgeLifecycleReady, Result: busy}
	if err = system.NoSender().Tell(ctx, pid, ready); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-busy:
		if result.Accepted || result.Reason != "durable persistence is busy" {
			t.Fatalf("READY race was not classified transient busy: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("READY race did not return while persistence was busy")
	}
	store.release <- nil
	select {
	case result := <-intentReceipt:
		if !result.Accepted {
			t.Fatalf("intent did not commit after release: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("intent receipt missing after release")
	}
	settled := make(chan application.BridgeResult, 1)
	retry := *ready
	retry.Result = settled
	if err = system.NoSender().Tell(ctx, pid, &retry); err != nil {
		t.Fatal(err)
	}
	select {
	case <-store.started:
		store.release <- nil
	case result := <-settled:
		if !result.Accepted {
			t.Fatalf("READY retry did not converge: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("READY retry persistence did not start")
	}
	select {
	case result := <-settled:
		if !result.Accepted {
			t.Fatalf("READY retry did not converge: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("READY retry did not complete")
	}
	if !record.Binding.BridgeReady || record.Binding.State != application.HostedPiRuntimeReady {
		t.Fatalf("READY retry regressed runtime binding: %#v", record.Binding)
	}
	failed := make(chan application.BridgeResult, 1)
	bad := retry
	bad.Event = application.BridgeLifecycleEvent(99)
	bad.Result = failed
	if err = system.NoSender().Tell(ctx, pid, &bad); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-failed:
		if result.Accepted || result.Reason != "unknown hosted bridge lifecycle event" {
			t.Fatalf("non-busy lifecycle error did not fail closed: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("non-busy lifecycle error did not respond")
	}
}

func TestAttachAgentIdempotentSubsetReattachBypassesDurableBusy(t *testing.T) {
	ctx := context.Background()
	system, err := actor.NewActorSystem("attach-idempotent-test")
	if err != nil {
		t.Fatal(err)
	}
	if err = system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	defer system.Stop(ctx)
	store := &blockingStore{started: make(chan application.DurableHostedRecord, 1), release: make(chan error, 1)}
	writer, err := system.Spawn(ctx, "writer", &HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	binding := application.InactiveHostedPiRuntimeBinding()
	state := application.DurableAgentState{Fence: 5, Attachments: []application.DurableAttachment{{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: "persisted-handle", Fence: 5, Capabilities: []string{"ask", "observe", "send"}}}}
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "target", Binding: binding, AgentState: state}
	pid, err := system.Spawn(ctx, "agent", NewAgentActor(&application.RegisterAgent{AgentID: "target", HostedPiRuntime: binding, AllowedCapability: []string{"ask", "control_abort", "observe", "send"}, PersistencePID: writer, DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	pendingAttach := make(chan application.AttachResult, 1)
	if err = system.NoSender().Tell(ctx, pid, &application.AttachAgent{SessionID: "other-session", GenerationID: "other-generation", Principal: "hosted:source", RequestedCapabilities: []string{"observe", "send"}, IssuedHandle: "other-handle", Result: pendingAttach}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-store.started:
	case <-time.After(time.Second):
		t.Fatal("attach mutation did not enter pending durable state")
	}

	value, err := system.NoSender().Ask(ctx, pid, &application.AttachAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", RequestedCapabilities: []string{"observe", "send"}, IssuedHandle: "fresh-handle"}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	attached := value.(*application.AttachResult)
	if !attached.Completed || attached.Handle != "persisted-handle" || attached.Fence != 5 {
		t.Fatalf("subset reattach did not return existing fence: %#v", attached)
	}

	value, err = system.NoSender().Ask(ctx, pid, &application.AttachAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:other", RequestedCapabilities: []string{"observe", "send"}, IssuedHandle: "wrong-principal"}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if result := value.(*application.AttachResult); result.Completed || result.Reason == "durable persistence is busy" || result.Reason == "" {
		t.Fatalf("wrong-principal reattach did not fail closed before durable busy: %#v", result)
	}

	value, err = system.NoSender().Ask(ctx, pid, &application.AttachAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", RequestedCapabilities: []string{"observe", "send", "control_abort"}, IssuedHandle: "broader-handle"}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if result := value.(*application.AttachResult); result.Completed {
		t.Fatalf("broader capability attach silently reused existing fence: %#v", result)
	}

	store.release <- nil
	select {
	case result := <-pendingAttach:
		if !result.Completed {
			t.Fatalf("pending attach rejected after release: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("pending attach result missing after release")
	}
}

func TestDurableMutationFailureRestoresDiskBeforeRejectingReceipt(t *testing.T) {
	ctx := context.Background()
	system, err := actor.NewActorSystem("durable-rollback-test")
	if err != nil {
		t.Fatal(err)
	}
	if err = system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	defer system.Stop(ctx)
	store := &blockingStore{started: make(chan application.DurableHostedRecord, 2), release: make(chan error, 2)}
	writer, err := system.Spawn(ctx, "writer", &HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.State, binding.BridgeReady, binding.RuntimeID, binding.Incarnation = application.HostedPiRuntimeReady, true, "runtime", 1
	state := application.DurableAgentState{Fence: 1, BridgeFence: 1, BridgeReady: true, BridgeDeclaredReady: true, BridgeSession: "session", BridgeGeneration: "generation", BridgePrincipal: "hosted:source", BridgeHandle: "handle", BridgePiSession: "pi", Attachments: []application.DurableAttachment{{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: "handle", Fence: 1, Capabilities: []string{"send", "hosted_bridge"}}}}
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "target", Binding: binding, AgentState: state}
	pid, err := system.Spawn(ctx, "agent", NewAgentActor(&application.RegisterAgent{AgentID: "target", HostedPiRuntime: binding, AllowedCapability: []string{"send", "hosted_bridge"}, PersistencePID: writer, DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	receipt := make(chan application.BridgeIntentResult, 1)
	intent := &application.BridgeIntent{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: "handle", Fence: 1, SourceAgentID: "source", TargetAgentID: "target", RequestID: "request", RequiredCapability: "send", DedupeID: "dedupe", ChainID: "chain", Deadline: time.Now().Add(time.Minute), HopLimit: 2, SourceMutationSequence: 1, Mode: application.BridgeMessageTell, Payload: []byte("payload"), Receipt: receipt}
	if err = system.NoSender().Tell(ctx, pid, intent); err != nil {
		t.Fatal(err)
	}
	<-store.started
	store.release <- errors.New("injected fsync uncertainty")
	rollback := <-store.started
	if len(rollback.AgentState.BridgeDeliveries) != 0 {
		t.Fatal("rollback persistence retained the rejected delivery")
	}
	select {
	case result := <-receipt:
		t.Fatalf("receipt was released before rollback fsync: %#v", result)
	default:
	}
	store.release <- nil
	select {
	case result := <-receipt:
		if result.Accepted || result.Reason == "" {
			t.Fatalf("failed durable mutation was accepted: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("failed durable mutation receipt missing after rollback")
	}
	poll, err := system.NoSender().Ask(ctx, pid, &application.PollBridge{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: "handle", Fence: 1}, time.Second)
	if err != nil || len(poll.(*application.BridgePollResult).Deliveries) != 0 {
		t.Fatalf("rejected delivery remained observable: %#v %v", poll, err)
	}
}

func TestDurableSessionRevocationPersistsBeforeCleanupAcknowledgement(t *testing.T) {
	ctx := context.Background()
	system, err := actor.NewActorSystem("durable-drop-test")
	if err != nil {
		t.Fatal(err)
	}
	if err = system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	defer system.Stop(ctx)
	store := &blockingStore{started: make(chan application.DurableHostedRecord, 1), release: make(chan error, 1)}
	writer, err := system.Spawn(ctx, "writer", &HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.RuntimeID, binding.Incarnation = "runtime", 1
	state := application.DurableAgentState{Fence: 1, Attachments: []application.DurableAttachment{{SessionID: "session", GenerationID: "generation", Principal: "principal", Handle: "handle", Fence: 1, Capabilities: []string{"observe"}}}}
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "target", Binding: binding, AgentState: state}
	pid, err := system.Spawn(ctx, "agent", NewAgentActor(&application.RegisterAgent{AgentID: "target", HostedPiRuntime: binding, AllowedCapability: []string{"observe"}, PersistencePID: writer, DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	result := make(chan application.OperationResult, 1)
	if err = system.NoSender().Tell(ctx, pid, &application.DropSession{SessionID: "session", GenerationID: "generation", Result: result}); err != nil {
		t.Fatal(err)
	}
	persisted := <-store.started
	if len(persisted.AgentState.Attachments) != 0 || len(persisted.AgentState.Revoked) != 1 {
		t.Fatalf("revocation was not represented in durable state: %#v", persisted.AgentState)
	}
	select {
	case value := <-result:
		t.Fatalf("cleanup acknowledged before revocation fsync: %#v", value)
	default:
	}
	store.release <- nil
	select {
	case value := <-result:
		if !value.Completed {
			t.Fatalf("durable cleanup rejected: %#v", value)
		}
	case <-time.After(time.Second):
		t.Fatal("durable cleanup acknowledgement missing")
	}
}
