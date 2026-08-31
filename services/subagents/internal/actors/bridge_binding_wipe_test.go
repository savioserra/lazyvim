package actors

import (
	"context"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

type captureStore struct {
	saved chan application.DurableHostedRecord
}

func (s *captureStore) Save(_ context.Context, r application.DurableHostedRecord) error {
	s.saved <- r
	return nil
}
func (*captureStore) Remove(context.Context, string) error { return nil }

type wipeHarness struct {
	system     actor.ActorSystem
	agent      *actor.PID
	supervisor *actor.PID
	store      *captureStore
}

func spawnWipeHarness(t *testing.T, state application.DurableAgentState, binding application.HostedPiRuntimeBinding) *wipeHarness {
	t.Helper()
	ctx := context.Background()
	system, err := actor.NewActorSystem("bridge-wipe-test")
	if err != nil {
		t.Fatal(err)
	}
	if err = system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = system.Stop(ctx) })
	store := &captureStore{saved: make(chan application.DurableHostedRecord, 8)}
	writer, err := system.Spawn(ctx, "wipe-writer", &HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	supervisor, err := system.Spawn(ctx, "wipe-supervisor", &PersistenceSupervisor{})
	if err != nil {
		t.Fatal(err)
	}
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "wipe-agent", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: "runtime"}, Binding: binding, AgentState: state}
	pid, err := system.Spawn(ctx, "wipe-agent", NewAgentActor(&application.RegisterAgent{AgentID: "wipe-agent", AuthorityBinding: record.AuthorityBinding, HostedPiRuntime: binding, AllowedCapability: []string{"send", "hosted_bridge"}, PersistencePID: writer, PersistenceSupervisor: supervisor, DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	runtimePID, err := system.Spawn(ctx, "wipe-runtime-dummy", &HostedPiRuntimeActor{})
	if err != nil {
		t.Fatal(err)
	}
	if err = system.NoSender().Tell(ctx, pid, &application.BindHostedPiRuntimeActor{PID: runtimePID}); err != nil {
		t.Fatal(err)
	}
	return &wipeHarness{system: system, agent: pid, supervisor: supervisor, store: store}
}

func (h *wipeHarness) ask(message any) any {
	t := time.Second
	value, err := h.system.NoSender().Ask(context.Background(), h.agent, message, t)
	if err != nil {
		return err
	}
	return value
}

func liveBridgeWipeState() (application.DurableAgentState, application.HostedPiRuntimeBinding) {
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.State = application.HostedPiRuntimeReady
	binding.RuntimeID, binding.Incarnation = "runtime", 1
	binding.BridgeReady = true
	state := application.DurableAgentState{Fence: 1, BridgeFence: 1, BridgeReady: true, BridgeDeclaredReady: true, BridgeSession: "session", BridgeGeneration: "generation", BridgePrincipal: "hosted:source", BridgeHandle: "handle", BridgePiSession: "pi", Attachments: []application.DurableAttachment{{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: "handle", Fence: 1, Capabilities: []string{"send", "hosted_bridge"}}}}
	return state, binding
}

// TestDropSessionRefusesLiveHostedBridgeBindingWipe guards the bridge-binding
// wipe incident: a session coordination drop arriving while the exact runtime
// is live must never null the durable bridge binding, revoke its generation,
// and unlink its attachment, because the still-connected Pi WebSocket could
// then never reattach and tasks would stall forever while health stayed ready.
func TestDropSessionRefusesLiveHostedBridgeBindingWipe(t *testing.T) {
	state, binding := liveBridgeWipeState()
	harness := spawnWipeHarness(t, state, binding)
	value := harness.ask(&application.HostedPiRuntimeStatus{})
	status, ok := value.(*application.HostedPiRuntimeBinding)
	if !ok || !status.BridgeReady || status.State != application.HostedPiRuntimeReady {
		t.Fatalf("live bridge binding did not report ready: %#v", value)
	}
	if err := harness.system.NoSender().Tell(context.Background(), harness.agent, &application.DropSession{SessionID: "session", GenerationID: "generation"}); err != nil {
		t.Fatal(err)
	}
	select {
	case persisted := <-harness.store.saved:
		t.Fatalf("live bridge binding wipe was persisted: %#v", persisted.AgentState)
	case <-time.After(200 * time.Millisecond):
	}
	value = harness.ask(&application.HostedPiRuntimeStatus{})
	status, ok = value.(*application.HostedPiRuntimeBinding)
	if !ok || status.State != application.HostedPiRuntimeDegraded || status.BridgeReady {
		t.Fatalf("refused wipe did not degrade the runtime fail-closed: %#v", value)
	}
	quarantine, err := harness.system.NoSender().Ask(context.Background(), harness.supervisor, &application.DurableQuarantineStatus{}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	quarantined, ok := quarantine.(*application.DurableQuarantineState)
	if !ok || !quarantined.FailClosed || quarantined.Items["wipe-agent"] == "" {
		t.Fatalf("refused wipe was not quarantined: %#v", quarantine)
	}
}

// TestDropSessionRetiresBridgeBindingAfterRuntimeStop is the control: once the
// exact runtime is stopped, the same coordination drop retires the bridge
// binding durably as before.
func TestDropSessionRetiresBridgeBindingAfterRuntimeStop(t *testing.T) {
	state, binding := liveBridgeWipeState()
	harness := spawnWipeHarness(t, state, binding)
	stopped := binding
	stopped.State = application.HostedPiRuntimeStopped
	stopped.BridgeReady = false
	if err := harness.system.NoSender().Tell(context.Background(), harness.agent, &application.HostedPiRuntimeStateChanged{AgentID: "wipe-agent", Binding: stopped}); err != nil {
		t.Fatal(err)
	}
	if err := harness.system.NoSender().Tell(context.Background(), harness.agent, &application.DropSession{SessionID: "session", GenerationID: "generation"}); err != nil {
		t.Fatal(err)
	}
	select {
	case persisted := <-harness.store.saved:
		if persisted.AgentState.BridgeSession != "" || persisted.AgentState.BridgePiSession != "" {
			t.Fatalf("stopped runtime drop did not retire the bridge binding: %#v", persisted.AgentState)
		}
	case <-time.After(time.Second):
		t.Fatal("stopped runtime drop was not persisted")
	}
}

// TestBridgeReadinessReportDerivesFromLiveBindingSession guards the reporting
// half of the incident: bridge readiness must derive from the live fenced
// bridge session, never from a persisted or stale binding flag alone.
func TestBridgeReadinessReportDerivesFromLiveBindingSession(t *testing.T) {
	state, binding := liveBridgeWipeState()
	state.BridgeDeclaredReady = false
	harness := spawnWipeHarness(t, state, binding)
	value := harness.ask(&application.HostedPiRuntimeStatus{})
	if status, ok := value.(*application.HostedPiRuntimeBinding); !ok || status.BridgeReady {
		t.Fatalf("stale binding flag reported ready without a live declared bridge session: %#v", value)
	}
}
