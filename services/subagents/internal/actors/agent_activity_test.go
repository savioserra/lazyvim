package actors

import (
	"context"
	"crypto/sha256"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
	"github.com/tochemey/goakt/v4/supervisor"
)

func TestAgentActivityMutationCommitsBeforeResponseAndRestores(t *testing.T) {
	ctx := context.Background()
	system, err := actor.NewActorSystem("activity-persist-test")
	if err != nil {
		t.Fatal(err)
	}
	if err = system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	defer system.Stop(ctx)
	store := &blockingStore{started: make(chan application.DurableHostedRecord, 1), release: make(chan error, 1)}
	writer, err := system.Spawn(ctx, "activity-writer", &HostedStateWriterActor{Store: store}, actor.WithSupervisor(supervisor.NewSupervisor(supervisor.WithAnyErrorDirective(supervisor.RestartDirective))))
	if err != nil {
		t.Fatal(err)
	}
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.State = application.HostedPiRuntimeReady
	binding.RuntimeID = "runtime"
	binding.Incarnation = 1
	state := application.DurableAgentState{Revision: 1, Fence: 1, BridgeSession: "session", BridgeGeneration: "generation", BridgePrincipal: "hosted:alpha", BridgeHandle: "handle", BridgeFence: 1, Attachments: []application.DurableAttachment{{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: "handle", Fence: 1, Capabilities: []string{"hosted_bridge", "activity_write"}}}}
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "alpha", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: "runtime"}, Binding: binding, AgentState: state}
	pid, err := system.Spawn(ctx, "activity-agent", NewAgentActor(&application.RegisterAgent{AgentID: "alpha", AuthorityBinding: record.AuthorityBinding, HostedPiRuntime: binding, AllowedCapability: []string{"hosted_bridge", "activity_write"}, PersistencePID: writer, DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	result := make(chan application.AgentActivityMutationResult, 1)
	digest := sha256.Sum256([]byte("set-alpha"))
	if err := system.NoSender().Tell(ctx, pid, &application.AgentActivityMutation{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", AgentID: "alpha", Handle: "handle", Fence: 1, Operation: application.AgentActivityOperationSet, ActivityKey: "tool", Label: "Editing", Details: "owner-private", DedupeID: "dedupe-one", PayloadDigest: digest, Result: result}); err != nil {
		t.Fatal(err)
	}
	var persisted application.DurableHostedRecord
	select {
	case persisted = <-store.started:
	case <-result:
		t.Fatal("activity response preceded durable persistence")
	case <-time.After(time.Second):
		t.Fatal("activity persistence did not start")
	}
	if len(persisted.AgentState.Activity.Values) != 1 || persisted.AgentState.Activity.Values[0].Details != "owner-private" {
		t.Fatalf("activity was not persisted with owner-private details: %#v", persisted.AgentState.Activity)
	}
	select {
	case <-result:
		t.Fatal("activity response arrived before fsync release")
	default:
	}
	store.release <- nil
	var accepted application.AgentActivityMutationResult
	select {
	case accepted = <-result:
	case <-time.After(time.Second):
		t.Fatal("activity response missing")
	}
	if !accepted.Accepted || accepted.Revision != 2 || accepted.ActivityEpoch != 1 {
		t.Fatalf("unexpected accepted result: %#v", accepted)
	}
	reloaded, err := system.Spawn(ctx, "activity-agent-reloaded", NewAgentActor(&application.RegisterAgent{AgentID: "alpha", AuthorityBinding: record.AuthorityBinding, HostedPiRuntime: binding, AllowedCapability: []string{"hosted_bridge", "activity_write"}, DurableRecord: &persisted}))
	if err != nil {
		t.Fatal(err)
	}
	dup := make(chan application.AgentActivityMutationResult, 1)
	if err := system.NoSender().Tell(ctx, reloaded, &application.AgentActivityMutation{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", AgentID: "alpha", Handle: "handle", Fence: 1, Operation: application.AgentActivityOperationSet, ActivityKey: "tool", Label: "Editing", Details: "owner-private", DedupeID: "dedupe-one", PayloadDigest: digest, Result: dup}); err != nil {
		t.Fatal(err)
	}
	select {
	case replay := <-dup:
		if replay != accepted {
			t.Fatalf("idempotent replay changed result: %#v vs %#v", replay, accepted)
		}
	case <-time.After(time.Second):
		t.Fatal("idempotent replay missing")
	}
}

func TestAgentActivityRejectsCollisionStaleAndRedactedClearTombstone(t *testing.T) {
	ctx := context.Background()
	system, err := actor.NewActorSystem("activity-reject-test")
	if err != nil {
		t.Fatal(err)
	}
	if err = system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	defer system.Stop(ctx)
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.RuntimeID = "runtime"
	binding.Incarnation = 1
	state := application.DurableAgentState{Revision: 1, Fence: 1, BridgeSession: "session", BridgeGeneration: "generation", BridgePrincipal: "hosted:alpha", BridgeHandle: "handle", BridgeFence: 1, Attachments: []application.DurableAttachment{{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: "handle", Fence: 1, Capabilities: []string{"hosted_bridge", "activity_write"}}}}
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "alpha", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: "runtime"}, Binding: binding, AgentState: state}
	pid, err := system.Spawn(ctx, "activity-reject-agent", NewAgentActor(&application.RegisterAgent{AgentID: "alpha", AuthorityBinding: record.AuthorityBinding, HostedPiRuntime: binding, AllowedCapability: []string{"hosted_bridge", "activity_write"}, DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	task := func(m application.AgentActivityMutation) application.AgentActivityMutationResult {
		ch := make(chan application.AgentActivityMutationResult, 1)
		m.Result = ch
		if err := system.NoSender().Tell(ctx, pid, &m); err != nil {
			t.Fatal(err)
		}
		select {
		case r := <-ch:
			return r
		case <-time.After(time.Second):
			t.Fatal("activity result missing")
		}
		return application.AgentActivityMutationResult{}
	}
	d1 := sha256.Sum256([]byte("one"))
	d2 := sha256.Sum256([]byte("two"))
	base := application.AgentActivityMutation{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", AgentID: "alpha", Handle: "handle", Fence: 1, Operation: application.AgentActivityOperationSet, ActivityKey: "focus", Label: "Review", DedupeID: "same", PayloadDigest: d1}
	first := task(base)
	if !first.Accepted {
		t.Fatalf("initial set rejected: %#v", first)
	}
	base.PayloadDigest = d2
	if collision := task(base); collision.Accepted || collision.Reason == "" {
		t.Fatalf("collision did not fail closed: %#v", collision)
	}
	stale := base
	stale.DedupeID = "stale"
	stale.PayloadDigest = sha256.Sum256([]byte("stale"))
	stale.CurrentRevision = first.Revision - 1
	if result := task(stale); result.Accepted || result.Reason == "" {
		t.Fatalf("stale revision accepted: %#v", result)
	}
	redacted := base
	redacted.DedupeID = "redacted"
	redacted.PayloadDigest = sha256.Sum256([]byte("redacted"))
	redacted.Label = "[redacted]"
	if result := task(redacted); result.Accepted || result.Reason == "" {
		t.Fatalf("redacted value accepted: %#v", result)
	}
	clear := base
	clear.DedupeID = "clear"
	clear.PayloadDigest = sha256.Sum256([]byte("clear"))
	clear.Operation = application.AgentActivityOperationClear
	clear.Label = ""
	if result := task(clear); !result.Accepted || result.ActivityEpoch != 2 {
		t.Fatalf("clear tombstone rejected: %#v", result)
	}
	poll, err := system.NoSender().Ask(ctx, pid, &application.PollBridge{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: "handle", Fence: 1, AfterSequence: 0, MaxItems: 64}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	polled := poll.(*application.BridgePollResult)
	if len(polled.ActivityEvents) != 2 || !polled.ActivityEvents[1].Activity.Cleared || polled.ActivityEvents[1].Activity.ActivityKey != "focus" {
		t.Fatalf("activity set/clear replay did not preserve clear tombstone: %#v", polled.ActivityEvents)
	}
}
