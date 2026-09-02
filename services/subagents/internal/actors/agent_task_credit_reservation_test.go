package actors_test

import (
	"context"
	"crypto/sha256"
	"fmt"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
)

// spawnUnbridgedAgent spawns a real target agent whose credit grants flow but
// whose bridge is deliberately not connected, so task acceptance is refused
// while the credit machinery stays live. Grants are immediate: no durable
// persistence writer is bound.
func spawnUnbridgedAgent(t *testing.T, ctx context.Context, system goakt.ActorSystem, agent string) *goakt.PID {
	t.Helper()
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.State = application.HostedPiRuntimeReady
	binding.RuntimeID = "runtime-" + agent
	binding.Incarnation = 1
	pid, err := system.Spawn(ctx, "agent-"+agent, actors.NewAgentActor(&application.RegisterAgent{AgentID: agent, AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: "runtime-" + agent}, HostedPiRuntime: binding, AllowedCapability: []string{"send"}}))
	if err != nil {
		t.Fatal(err)
	}
	return pid
}

func requestCredit(t *testing.T, ctx context.Context, probe *taskPeerProbe, target *goakt.PID, taskID, requestID, dedupeID string, digest [32]byte) *application.TaskCreditGranted {
	t.Helper()
	if err := probe.tell(ctx, target, &application.RequestTaskCredit{TaskID: taskID, RequestID: requestID, DedupeID: dedupeID, ChainID: "chain", Deadline: time.Now().Add(time.Minute), PayloadDigest: digest}); err != nil {
		t.Fatal(err)
	}
	deadline := time.After(time.Second)
	for {
		probe.mu.Lock()
		for index, message := range probe.received {
			grant, ok := message.(*application.TaskCreditGranted)
			if !ok {
				continue
			}
			probe.received = append(probe.received[:index], probe.received[index+1:]...)
			probe.mu.Unlock()
			if grant.Credit.TaskID != taskID {
				t.Fatalf("target %s granted credit for %s, want %s", target.Name(), grant.Credit.TaskID, taskID)
			}
			return grant
		}
		probe.mu.Unlock()
		select {
		case <-probe.notify:
		case <-deadline:
			t.Fatalf("target %s never granted credit for %s", target.Name(), taskID)
			return nil
		}
	}
}

// nextAccepted consumes ActorTaskAccepted verdicts in arrival order so
// sequential deliveries assert on their own reply instead of re-matching the
// first one in the probe mailbox.
func nextAccepted(t *testing.T, probe *taskPeerProbe, timeout time.Duration) *application.ActorTaskAccepted {
	t.Helper()
	deadline := time.After(timeout)
	for {
		probe.mu.Lock()
		for index, message := range probe.received {
			accepted, ok := message.(*application.ActorTaskAccepted)
			if !ok {
				continue
			}
			probe.received = append(probe.received[:index], probe.received[index+1:]...)
			probe.mu.Unlock()
			return accepted
		}
		probe.mu.Unlock()
		select {
		case <-probe.notify:
		case <-deadline:
			t.Fatal("target never delivered the awaited acceptance verdict")
			return nil
		}
	}
}

// TestRejectedActorTaskKeepsReservationAcrossInterleavedCreditRequests pins
// the TASK-12b live failure: a target that grants a credit and then refuses
// the task (bridge not ready, capacity, duplicate) must NOT burn the granted
// reservation, because the source outbox still holds the credit and redrives
// it within the lease. The regression interleaves the original grant with
// credit requests from the same source for other items and other targets:
// none of them may clear the live reservation, and the redriven task must
// keep hitting the real acceptance refusal instead of a vanished-reservation
// reject.
func TestRejectedActorTaskKeepsReservationAcrossInterleavedCreditRequests(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("credit-reservation-retain", goakt.WithPubSub())
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
	target := spawnUnbridgedAgent(t, ctx, system, "delta")
	otherTarget := spawnUnbridgedAgent(t, ctx, system, "echo")
	source := spawnTaskPeer(t, ctx, system, "reservation-source")
	payload := []byte("reservation payload")
	digest := sha256.Sum256(payload)

	// Original grant for task A on the rejecting target.
	grantedA := requestCredit(t, ctx, source, target, "delta-task-a", "request-a", "dedupe-a", digest)
	if grantedA.Credit.TargetEpoch != 1 {
		t.Fatalf("first grant on target carried epoch %d, want 1", grantedA.Credit.TargetEpoch)
	}
	// Interleaved credit requests from the same source: another item on the
	// SAME target and an item on ANOTHER target.
	grantedOther := requestCredit(t, ctx, source, otherTarget, "echo-task-b", "request-b", "dedupe-b", digest)
	grantedSameTarget := requestCredit(t, ctx, source, target, "delta-task-c", "request-c", "dedupe-c", digest)
	if grantedSameTarget.Credit.TargetEpoch != 2 || grantedOther.Credit.TargetEpoch != 1 {
		t.Fatalf("interleaved grants rotated epochs wrongly: same-target=%d other-target=%d", grantedSameTarget.Credit.TargetEpoch, grantedOther.Credit.TargetEpoch)
	}

	task := &application.ActorTask{Credit: grantedA.Credit, SourcePeer: application.CommunicationPeer{StableID: "alpha"}, TargetPeer: application.CommunicationPeer{StableID: "delta"}, RequestID: "request-a", DedupeID: "dedupe-a", ChainID: "chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: payload}
	if err = source.tell(ctx, target, task); err != nil {
		t.Fatal(err)
	}
	rejected := nextAccepted(t, source, time.Second)
	if rejected.Accepted || rejected.Reason != "actor task rejected" {
		t.Fatalf("unbridged target did not refuse the first delivery: %#v", rejected)
	}
	// The source outbox redrives the SAME held credit: the reservation must
	// still exist, so the refusal must repeat with the real acceptance reason
	// instead of a vanished-reservation stale-credit reject.
	if err = source.tell(ctx, target, task); err != nil {
		t.Fatal(err)
	}
	redrive := nextAccepted(t, source, time.Second)
	if redrive.Accepted || redrive.Reason != "actor task rejected" {
		t.Fatalf("rejected task burned its credit reservation: redrive answered %#v, want reason actor task rejected", redrive)
	}
	// A later grant on the same target must still observe the live lease and
	// count it against task capacity, proving the reservation was retained in
	// the target's own accounting rather than resurrected per delivery.
	if followUp := requestCredit(t, ctx, source, target, "delta-task-d", "request-d", "dedupe-d", digest); followUp.Credit.TargetEpoch != 3 {
		t.Fatalf("post-reject grant carried epoch %d, want 3", followUp.Credit.TargetEpoch)
	}
}

func TestActorTaskAcceptsSparseGlobalSourceMutationSequences(t *testing.T) {
	target := newBridgeHarness(t, "credit-sparse-source-sequence", "bravo", "alpha")
	ctx := context.Background()
	source := spawnTaskPeer(t, ctx, target.system, "sparse-sequence-source")
	for index, sequence := range []uint64{15, 20} {
		payload := []byte("sparse sequence payload")
		digest := sha256.Sum256(payload)
		taskID := fmt.Sprintf("bravo-task-sparse-%d", sequence)
		requestID := fmt.Sprintf("request-sparse-%d", sequence)
		dedupeID := fmt.Sprintf("dedupe-sparse-%d", sequence)
		granted := requestCredit(t, ctx, source, target.pid, taskID, requestID, dedupeID, digest)
		task := &application.ActorTask{Credit: granted.Credit, SourcePeer: application.CommunicationPeer{StableID: "alpha"}, TargetPeer: application.CommunicationPeer{StableID: "bravo"}, RequestID: requestID, DedupeID: dedupeID, ChainID: fmt.Sprintf("chain-sparse-%d", sequence), RequiredCapability: "send", SourceMutationSequence: sequence, Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: payload}
		if err := source.tell(ctx, target.pid, task); err != nil {
			t.Fatal(err)
		}
		if accepted := nextAccepted(t, source, time.Second); !accepted.Accepted {
			t.Fatalf("target rejected sparse global source sequence %d: %#v", sequence, accepted)
		}
		if deliveries := target.poll().Deliveries; len(deliveries) != index+1 {
			t.Fatalf("sparse sequence %d produced %d deliveries, want %d", sequence, len(deliveries), index+1)
		}
	}
}

// TestAcceptedActorTaskConsumesItsCreditReservation pins the consumption half
// of the invariant: a SUCCESSFUL acceptance is exactly-once, so the credit is
// spent and any duplicate redelivery of the same task must reject as a stale
// credit rather than be delivered twice.
func TestAcceptedActorTaskConsumesItsCreditReservation(t *testing.T) {
	target := newBridgeHarness(t, "credit-reservation-consume", "bravo", "alpha")
	ctx := context.Background()
	source := spawnTaskPeer(t, ctx, target.system, "consuming-source")
	payload := []byte("consumed credit payload")
	digest := sha256.Sum256(payload)
	granted := requestCredit(t, ctx, source, target.pid, "bravo-task-consume", "request-consume", "dedupe-consume", digest)
	task := &application.ActorTask{Credit: granted.Credit, SourcePeer: application.CommunicationPeer{StableID: "alpha"}, TargetPeer: application.CommunicationPeer{StableID: "bravo"}, RequestID: "request-consume", DedupeID: "dedupe-consume", ChainID: "chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: payload}
	if err := source.tell(ctx, target.pid, task); err != nil {
		t.Fatal(err)
	}
	accepted := nextAccepted(t, source, time.Second)
	if !accepted.Accepted {
		t.Fatalf("bridged target did not accept the credited task: %#v", accepted)
	}
	// The duplicate redelivery must reject: the reservation was consumed by
	// the successful acceptance.
	if err := source.tell(ctx, target.pid, task); err != nil {
		t.Fatal(err)
	}
	duplicate := nextAccepted(t, source, time.Second)
	if duplicate.Accepted || duplicate.Reason != "invalid, expired, duplicate, or stale task credit" {
		t.Fatalf("consumed credit was spendable twice: %#v", duplicate)
	}
	if deliveries := target.poll().Deliveries; len(deliveries) != 1 {
		t.Fatalf("credited task delivered %d times, want exactly 1", len(deliveries))
	}
}
