package actors

import (
	"crypto/sha256"
	"errors"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

func schedulerThread(id string, state application.AgentThreadState, sequence uint64, next time.Time) application.DurableAgentThread {
	return application.DurableAgentThread{SchemaVersion: application.DurableAgentThreadSchemaV1, ThreadID: id, Source: application.CommunicationPeer{StableID: "source"}, Target: application.CommunicationPeer{StableID: "target"}, RequestID: "request-" + id, DedupeID: "dedupe-" + id, ChainID: "chain-" + id, SourceMutationSequence: sequence, PayloadDigest: sha256.Sum256([]byte(id)), Mode: application.BridgeMessageAsk, Deadline: time.Unix(2_000_000_000, 0), HopLimit: 8, State: state, ActiveDeliverySequence: sequence, CompletionKey: "completion-" + id, NextAttempt: next}
}

func TestThreadSchedulerServesResumableAfterTwoNewTasks(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	a := &AgentActor{id: "target", threads: map[string]application.DurableAgentThread{}, threadScheduler: application.DurableThreadScheduler{SchemaVersion: application.DurableThreadSchedulerSchemaV1, AgentID: "target"}}
	for _, thread := range []application.DurableAgentThread{schedulerThread("new-1", application.AgentThreadQueued, 1, time.Time{}), schedulerThread("new-2", application.AgentThreadQueued, 2, time.Time{}), schedulerThread("resume", application.AgentThreadResumable, 3, now.Add(-time.Second))} {
		a.threads[thread.ThreadID] = thread
	}
	a.threadScheduler.Queue = []string{"new-1", "new-2"}
	a.threadScheduler.Resumable = []string{"resume"}
	for index, expected := range []string{"new-1", "new-2", "resume"} {
		selected, ok := a.chooseNextThread(now)
		if !ok || selected.ThreadID != expected {
			t.Fatalf("decision %d selected %#v, want %s", index, selected, expected)
		}
		a.threadScheduler.ActiveThreadID = ""
	}
	if a.threadScheduler.Epoch != 3 || a.threadScheduler.ActiveLease != 3 || a.threadScheduler.NewWorkDeficit != 0 {
		t.Fatalf("unexpected scheduler counters: %#v", a.threadScheduler)
	}
}

func TestThreadSchedulerSkipsResumableBackoffWithoutStarvingQueue(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	a := &AgentActor{id: "target", threads: map[string]application.DurableAgentThread{}, threadScheduler: application.DurableThreadScheduler{SchemaVersion: application.DurableThreadSchedulerSchemaV1, AgentID: "target", NewWorkDeficit: 2}}
	queued := schedulerThread("queued", application.AgentThreadQueued, 1, time.Time{})
	resume := schedulerThread("resume", application.AgentThreadResumable, 2, now.Add(time.Minute))
	a.threads[queued.ThreadID], a.threads[resume.ThreadID] = queued, resume
	a.threadScheduler.Queue, a.threadScheduler.Resumable = []string{queued.ThreadID}, []string{resume.ThreadID}
	selected, ok := a.chooseNextThread(now)
	if !ok || selected.ThreadID != queued.ThreadID {
		t.Fatalf("ineligible resumable blocked queued work: %#v", selected)
	}
}

func TestThreadAdmissionConvergesExactlyAndRejectsImmutableCollision(t *testing.T) {
	deadline := time.Unix(2_000_000_000, 0)
	intent := &application.BridgeIntent{SourceAgentID: "source", RequestID: "request", DedupeID: "dedupe", ChainID: "chain", SourceMutationSequence: 7, RequiredCapability: "ask", Deadline: deadline, HopLimit: 8, Mode: application.BridgeMessageAsk, Payload: []byte("payload")}
	fingerprint := application.NewAgentThreadFingerprint("target", intent)
	thread := schedulerThread(fingerprint.ThreadID(), application.AgentThreadQueued, 7, time.Time{})
	thread.Source = application.CommunicationPeer{StableID: "source"}
	thread.Target = application.CommunicationPeer{StableID: "target"}
	thread.RequestID, thread.DedupeID, thread.ChainID = intent.RequestID, intent.DedupeID, intent.ChainID
	thread.PayloadDigest, thread.RequiredCapability, thread.Deadline, thread.HopLimit, thread.Mode = fingerprint.PayloadDigest, intent.RequiredCapability, deadline, intent.HopLimit, intent.Mode
	a := &AgentActor{id: "target", threads: map[string]application.DurableAgentThread{thread.ThreadID: thread}, threadScheduler: application.DurableThreadScheduler{SchemaVersion: application.DurableThreadSchedulerSchemaV1, AgentID: "target"}}
	if retained, replay, err := a.findThreadAdmission(fingerprint); err != nil || !replay || retained.ThreadID != thread.ThreadID {
		t.Fatalf("exact admission did not converge: %#v %t %v", retained, replay, err)
	}
	collision := fingerprint
	collision.HopLimit++
	if _, _, err := a.findThreadAdmission(collision); !errors.Is(err, errThreadIdentityCollision) {
		t.Fatalf("immutable collision was accepted: %v", err)
	}
	sequenceReuse := fingerprint
	sequenceReuse.DedupeID = "different"
	if _, _, err := a.findThreadAdmission(sequenceReuse); !errors.Is(err, errThreadIdentityCollision) {
		t.Fatalf("source sequence reuse was accepted: %v", err)
	}
}
