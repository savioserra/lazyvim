package actors

import (
	"context"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

// TestTerminalAgentPersistsPristineInactiveBinding guards the writer half of
// the terminal restart incident: ensureTerminalAgent registers a terminal agent
// whose live binding carries display metadata, and the durable writer used to
// persist that metadata into the record binding. The reconcile validator only
// accepts the pristine inactive binding for terminal agents, so the daemon
// rejected its own records at restart ("invalid agent registration") and
// crash-looped. The durable binding must always round-trip pristine while
// role and display name travel as registration metadata.
func TestTerminalAgentPersistsPristineInactiveBinding(t *testing.T) {
	ctx := context.Background()
	system, err := actor.NewActorSystem("terminal-roundtrip-test")
	if err != nil {
		t.Fatal(err)
	}
	if err = system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	defer system.Stop(ctx)
	store := &captureStore{saved: make(chan application.DurableHostedRecord, 4)}
	writer, err := system.Spawn(ctx, "terminal-writer", &HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "hosted:terminal-writer", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "hosted:terminal-writer"}, Retention: "bounded", Recovery: "terminal-reattach", Binding: application.InactiveHostedPiRuntimeBinding()}
	pid, err := system.Spawn(ctx, "terminal-roundtrip-agent", NewAgentActor(&application.RegisterAgent{AgentID: "hosted:terminal-writer", Role: "TERMINAL PI", DisplayName: "TERMINAL PI", AuthorityBinding: record.AuthorityBinding, HostedPiRuntime: record.Binding, AllowedCapability: []string{"observe", "send"}, Retention: record.Retention, Recovery: record.Recovery, PersistencePID: writer, DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	if err = system.NoSender().Tell(ctx, pid, &application.DurableBarrier{}); err != nil {
		t.Fatal(err)
	}
	select {
	case persisted := <-store.saved:
		if persisted.Binding != application.InactiveHostedPiRuntimeBinding() {
			t.Fatalf("terminal durable binding did not round-trip pristine: %#v", persisted.Binding)
		}
	case <-time.After(time.Second):
		t.Fatal("terminal barrier persistence did not run")
	}
}
