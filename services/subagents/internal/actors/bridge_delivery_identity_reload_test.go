package actors_test

import (
	"context"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
)

// TestLegacyIdentitylessDeliveryReloadWithholdsRetiresAndUnblocks models the
// deployed incident: durable state persisted before acknowledgement identity
// existed reloads with a queued prompt delivery that no bridge client could
// ever acknowledge. The reloaded actor must withhold it from the bridge serve
// surface, retire it through the bounded deadline path instead of waiting for
// its deadline, and admit fresh prompt work again.
func TestLegacyIdentitylessDeliveryReloadWithholdsRetiresAndUnblocks(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("legacy-identity-reload", goakt.WithPubSub(), goakt.WithMessageRetention(time.Minute))
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
	store := &cursorAckStore{notify: make(chan struct{}, 8)}
	writer, err := system.Spawn(ctx, "legacy-writer", &actors.HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.State, binding.BridgeReady, binding.RuntimeID, binding.Incarnation = application.HostedPiRuntimeReady, true, "runtime-bravo", 1
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "bravo", Binding: binding, AgentState: application.DurableAgentState{BridgeReady: true}}
	pid, err := system.Spawn(ctx, "legacy-agent", actors.NewBridgeDeliveryFixtureAgent(&application.RegisterAgent{AgentID: "bravo", HostedPiRuntime: binding, AllowedCapability: []string{"send", "ask", "hosted_bridge"}, PersistencePID: writer, DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	tell := func(target *goakt.PID, message any) { _ = system.NoSender().Tell(ctx, target, message) }
	attachResults := make(chan application.AttachResult, 1)
	tell(pid, &application.AttachAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", RequestedCapabilities: []string{"send", "ask", "hosted_bridge"}, IssuedHandle: "handle", Result: attachResults})
	attached := awaitResult(t, attachResults, "attach")
	if !attached.Completed {
		t.Fatalf("attach failed: %#v", attached)
	}
	bridgeResults := make(chan application.BridgeResult, 1)
	tell(pid, &application.BridgeConnect{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", AgentID: "bravo", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime-bravo", Incarnation: 1, PiSessionID: "pi-bravo", Result: bridgeResults})
	if connected := awaitResult(t, bridgeResults, "connect"); !connected.Accepted {
		t.Fatalf("connect rejected: %#v", connected)
	}
	askIntent := func(target *goakt.PID, dedupe, chain string, sequence uint64) chan application.BridgeIntentResult {
		receipt := make(chan application.BridgeIntentResult, 1)
		tell(target, &application.BridgeIntent{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: attached.Handle, Fence: attached.Fence, SourceAgentID: "alpha", TargetAgentID: "bravo", RequestID: "request-" + dedupe, RequiredCapability: "ask", DedupeID: dedupe, ChainID: chain, Deadline: time.Now().Add(time.Minute), HopLimit: 4, SourceMutationSequence: sequence, Mode: application.BridgeMessageAsk, Payload: []byte("wake up"), Receipt: receipt})
		return receipt
	}
	if result := awaitResult(t, askIntent(pid, "legacy-dedupe", "legacy-chain", 1), "legacy ask"); !result.Accepted {
		t.Fatalf("legacy ask rejected: %#v", result)
	}
	store.waitForSave(t)
	poll := func(target *goakt.PID) []application.BridgeDelivery {
		value, err := system.NoSender().Ask(ctx, target, &application.PollBridge{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: attached.Handle, Fence: attached.Fence, MaxItems: 64}, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		return value.(*application.BridgePollResult).Deliveries
	}
	if deliveries := poll(pid); len(deliveries) != 1 || !deliveries[0].AckIdentityComplete() {
		t.Fatalf("fresh ask delivery must carry full acknowledgement identity: %#v", deliveries)
	}

	// Model a daemon restart onto durable state persisted before
	// acknowledgement identity existed: same queued prompt delivery, no
	// source scope token, no completion key, deadline far in the future.
	persisted := store.last()
	persisted.Binding = binding
	if len(persisted.AgentState.BridgeDeliveries) != 1 {
		t.Fatalf("expected one persisted delivery, found %d", len(persisted.AgentState.BridgeDeliveries))
	}
	persisted.AgentState.BridgeDeliveries[0].SourceScope = ""
	persisted.AgentState.BridgeDeliveries[0].CompletionKey = ""
	persisted.AgentState.BridgeDeliveries[0].Deadline = time.Now().Add(time.Hour)
	reloaded, err := system.Spawn(ctx, "legacy-agent-reloaded", actors.NewBridgeDeliveryFixtureAgent(&application.RegisterAgent{AgentID: "bravo", HostedPiRuntime: binding, AllowedCapability: []string{"send", "ask", "hosted_bridge"}, DurableRecord: &persisted}))
	if err != nil {
		t.Fatal(err)
	}

	// The identity-less delivery must never reach the bridge serve surface.
	if deliveries := poll(reloaded); len(deliveries) != 0 {
		t.Fatalf("legacy identity-less delivery was served after reload: %#v", deliveries)
	}

	// Retirement is scheduled immediately instead of waiting the full
	// deadline, so fresh prompt work must be admitted again within a bound.
	var admitted *application.BridgeIntentResult
	deadline := time.Now().Add(3 * time.Second)
	for admitted == nil && time.Now().Before(deadline) {
		receipt := askIntent(reloaded, "fresh-dedupe", "fresh-chain", 2)
		select {
		case result := <-receipt:
			if result.Accepted {
				admitted = &result
			}
		case <-time.After(50 * time.Millisecond):
			t.Fatal("fresh ask receipt never arrived")
		}
		if admitted == nil {
			time.Sleep(10 * time.Millisecond)
		}
	}
	if admitted == nil {
		t.Fatal("legacy identity-less delivery kept the prompt slot blocked past the bounded retirement window")
	}
	fresh := poll(reloaded)
	if len(fresh) != 1 || !fresh[0].AckIdentityComplete() {
		t.Fatalf("fresh reloaded delivery must carry full acknowledgement identity: %#v", fresh)
	}
	ack := identityAck("session", "generation", "hosted:alpha", attached.Handle, attached.Fence, "runtime-bravo", "pi-bravo", fresh[0], true, []byte("WAKE-OK"))
	ackResults := make(chan application.BridgeDeliveryAckResult, 1)
	ack.Completion = ackResults
	tell(reloaded, ack)
	result := awaitResult(t, ackResults, "fresh ack")
	if !result.Accepted || result.Cursor != fresh[0].Sequence {
		t.Fatalf("reloaded acknowledgement chain broken: %#v", result)
	}
}

// TestLegacyIdentitylessDeliveryWithUnresolvedScopeIsDroppedAtRestore closes
// the retirement gap: a legacy identity-less durable delivery whose owning
// mutation scope no longer resolves cannot be retired through the bounded
// deadline path, so the restore must drop it loudly instead of leaving a
// delivery that is neither served, acknowledged, nor retired — the exact
// invisible cursor stall observed in the deployed incident.
func TestLegacyIdentitylessDeliveryWithUnresolvedScopeIsDroppedAtRestore(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("legacy-unresolved-reload", goakt.WithPubSub(), goakt.WithMessageRetention(time.Minute))
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
	store := &cursorAckStore{notify: make(chan struct{}, 8)}
	writer, err := system.Spawn(ctx, "unresolved-writer", &actors.HostedStateWriterActor{Store: store})
	if err != nil {
		t.Fatal(err)
	}
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.State, binding.BridgeReady, binding.RuntimeID, binding.Incarnation = application.HostedPiRuntimeReady, true, "runtime-orphan", 1
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "orphan", Binding: binding, AgentState: application.DurableAgentState{BridgeReady: true}}
	pid, err := system.Spawn(ctx, "orphan-agent", actors.NewBridgeDeliveryFixtureAgent(&application.RegisterAgent{AgentID: "orphan", HostedPiRuntime: binding, AllowedCapability: []string{"send", "ask", "hosted_bridge"}, PersistencePID: writer, DurableRecord: &record}))
	if err != nil {
		t.Fatal(err)
	}
	tell := func(target *goakt.PID, message any) { _ = system.NoSender().Tell(ctx, target, message) }
	attachResults := make(chan application.AttachResult, 1)
	tell(pid, &application.AttachAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", RequestedCapabilities: []string{"send", "ask", "hosted_bridge"}, IssuedHandle: "handle", Result: attachResults})
	attached := awaitResult(t, attachResults, "attach")
	if !attached.Completed {
		t.Fatalf("attach failed: %#v", attached)
	}
	bridgeResults := make(chan application.BridgeResult, 1)
	tell(pid, &application.BridgeConnect{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", AgentID: "orphan", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime-orphan", Incarnation: 1, PiSessionID: "pi-orphan", Result: bridgeResults})
	if connected := awaitResult(t, bridgeResults, "connect"); !connected.Accepted {
		t.Fatalf("connect rejected: %#v", connected)
	}
	askReceipt := make(chan application.BridgeIntentResult, 1)
	tell(pid, &application.BridgeIntent{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: attached.Handle, Fence: attached.Fence, SourceAgentID: "alpha", TargetAgentID: "orphan", RequestID: "request-orphan", RequiredCapability: "ask", DedupeID: "orphan-dedupe", ChainID: "orphan-chain", Deadline: time.Now().Add(time.Minute), HopLimit: 4, SourceMutationSequence: 1, Mode: application.BridgeMessageAsk, Payload: []byte("wake up"), Receipt: askReceipt})
	if result := awaitResult(t, askReceipt, "orphan ask"); !result.Accepted {
		t.Fatalf("orphan ask rejected: %#v", result)
	}
	store.waitForSave(t)
	persisted := store.last()
	persisted.Binding = binding
	if len(persisted.AgentState.BridgeDeliveries) != 1 {
		t.Fatalf("expected one persisted delivery, found %d", len(persisted.AgentState.BridgeDeliveries))
	}
	// Model a durable record whose owning scope metadata was lost: the
	// delivery source key no longer maps to any mutation scope, so the bounded
	// deadline path can never retire it, and the identity is legacy-stripped.
	persisted.AgentState.BridgeDeliveries[0].SourceScope = ""
	persisted.AgentState.BridgeDeliveries[0].CompletionKey = ""
	persisted.AgentState.DeliverySources = nil
	reloaded, err := system.Spawn(ctx, "orphan-agent-reloaded", actors.NewBridgeDeliveryFixtureAgent(&application.RegisterAgent{AgentID: "orphan", HostedPiRuntime: binding, AllowedCapability: []string{"send", "ask", "hosted_bridge"}, DurableRecord: &persisted}))
	if err != nil {
		t.Fatal(err)
	}

	// The identity-less orphan is dropped at restore: never served, and it
	// must not keep the prompt queue blocked past the bounded window.
	poll := func(target *goakt.PID) []application.BridgeDelivery {
		value, err := system.NoSender().Ask(ctx, target, &application.PollBridge{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: attached.Handle, Fence: attached.Fence, MaxItems: 64}, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		return value.(*application.BridgePollResult).Deliveries
	}
	if deliveries := poll(reloaded); len(deliveries) != 0 {
		t.Fatalf("identity-less orphan delivery was served after reload: %#v", deliveries)
	}
	// The restore drop is asynchronous, so fresh prompt work must be admitted
	// again within a bounded window instead of staying blocked forever.
	var fresh *application.BridgeIntentResult
	var lastRejection string
	deadline := time.Now().Add(3 * time.Second)
	for fresh == nil && time.Now().Before(deadline) {
		receipt := make(chan application.BridgeIntentResult, 1)
		tell(reloaded, &application.BridgeIntent{SessionID: "session", GenerationID: "generation", Principal: "hosted:alpha", Handle: attached.Handle, Fence: attached.Fence, SourceAgentID: "alpha", TargetAgentID: "orphan", RequestID: "request-fresh", RequiredCapability: "ask", DedupeID: "fresh-orphan-dedupe", ChainID: "fresh-orphan-chain", Deadline: time.Now().Add(time.Minute), HopLimit: 4, SourceMutationSequence: 2, Mode: application.BridgeMessageAsk, Payload: []byte("wake again"), Receipt: receipt})
		select {
		case result := <-receipt:
			if result.Accepted {
				fresh = &result
			} else {
				lastRejection = result.Reason
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("fresh ask receipt never arrived (last rejection: %q)", lastRejection)
		}
		if fresh == nil {
			time.Sleep(10 * time.Millisecond)
		}
	}
	if fresh == nil {
		t.Fatalf("fresh ask stayed blocked behind a dropped orphan delivery (last rejection: %q)", lastRejection)
	}
	deliveries := poll(reloaded)
	if len(deliveries) != 1 || !deliveries[0].AckIdentityComplete() {
		t.Fatalf("fresh delivery after orphan drop must carry full acknowledgement identity: %#v", deliveries)
	}
}
