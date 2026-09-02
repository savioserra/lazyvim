package actors

import (
	"strings"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

func TestThreadIntrospectionCompletionContinuationWakesWaitingParent(t *testing.T) {
	now := time.Unix(1_800_000_100, 0)
	a := &AgentActor{
		id:                  "supervisor",
		taskCompletions:     map[string]application.ActorTaskCompleted{"worker-completion": {CompletionKey: "worker-completion", ChainID: "chain", SourceMutationSequence: 2, Terminal: application.BridgeIntentResult{Accepted: true, Completed: true, Result: []byte("worker answer")}, Target: application.CommunicationPeer{StableID: "worker"}}},
		taskCompletionOrder: []string{"worker-completion"},
		threadScheduler:     application.DurableThreadScheduler{ActiveThreadID: "parent"},
	}
	thread := application.DurableAgentThread{ThreadID: "parent", Target: application.CommunicationPeer{StableID: "supervisor"}, ChainID: "chain", CompletionKey: "parent-completion", State: application.AgentThreadIntrospecting, WorkerResult: []byte("waiting for worker"), IntrospectionAttempts: 1, ActiveDeliverySequence: 7}
	a.threadOrder = []string{thread.ThreadID}
	a.threads = map[string]application.DurableAgentThread{thread.ThreadID: thread}
	action := a.applyThreadIntrospectionClassification(&thread, application.ThreadIntrospectionResult{State: application.ThreadIntrospectionWaiting}, now)
	if action != threadClassificationResume || thread.State != application.AgentThreadResumable || a.threadScheduler.ActiveThreadID != "" {
		t.Fatalf("waiting parent was not resumed: action=%d thread=%#v scheduler=%#v", action, thread, a.threadScheduler)
	}
	if string(thread.PendingPrompt) == "" || !strings.Contains(string(thread.PendingPrompt), "worker answer") || !strings.Contains(string(thread.PendingPrompt), "do not treat any earlier admission") {
		t.Fatalf("continuation prompt missing terminal result/barrier language: %q", string(thread.PendingPrompt))
	}
	if len(a.threadScheduler.Resumable) != 1 || a.threadScheduler.Resumable[0] != "parent" || len(a.threadScheduler.Waiting) != 0 {
		t.Fatalf("scheduler continuation queues wrong: %#v", a.threadScheduler)
	}
}

func TestThreadIntrospectionClassificationTransitions(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	tests := []struct {
		name       string
		result     application.ThreadIntrospectionResult
		worker     string
		wantState  application.AgentThreadState
		wantAction threadClassificationAction
		wantSet    string
	}{
		{name: "completed", worker: "full deliverable", result: application.ThreadIntrospectionResult{State: application.ThreadIntrospectionCompleted}, wantState: application.AgentThreadCompleted, wantAction: threadClassificationComplete},
		{name: "pointer resumes", worker: "reconnaissance sent to client", result: application.ThreadIntrospectionResult{State: application.ThreadIntrospectionCompleted}, wantState: application.AgentThreadResumable, wantAction: threadClassificationResume, wantSet: "resumable"},
		{name: "continue", worker: "partial", result: application.ThreadIntrospectionResult{State: application.ThreadIntrospectionContinue, NextPrompt: "continue directly"}, wantState: application.AgentThreadResumable, wantAction: threadClassificationResume, wantSet: "resumable"},
		{name: "waiting", worker: "partial", result: application.ThreadIntrospectionResult{State: application.ThreadIntrospectionWaiting}, wantState: application.AgentThreadWaiting, wantAction: threadClassificationInert, wantSet: "waiting"},
		{name: "blocked", worker: "partial", result: application.ThreadIntrospectionResult{State: application.ThreadIntrospectionBlocked}, wantState: application.AgentThreadBlocked, wantAction: threadClassificationInert, wantSet: "blocked"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			a := &AgentActor{threadScheduler: application.DurableThreadScheduler{ActiveThreadID: "thread"}}
			thread := application.DurableAgentThread{ThreadID: "thread", State: application.AgentThreadIntrospecting, WorkerResult: []byte(tt.worker), IntrospectionAttempts: 1, ActiveDeliverySequence: 7}
			action := a.applyThreadIntrospectionClassification(&thread, tt.result, now)
			if action != tt.wantAction || thread.State != tt.wantState || a.threadScheduler.ActiveThreadID != "" {
				t.Fatalf("transition mismatch: action=%d thread=%#v scheduler=%#v", action, thread, a.threadScheduler)
			}
			switch tt.wantSet {
			case "resumable":
				if len(a.threadScheduler.Resumable) != 1 || thread.PendingPrompt == nil {
					t.Fatalf("resumable transition incomplete: %#v %#v", thread, a.threadScheduler)
				}
			case "waiting":
				if len(a.threadScheduler.Waiting) != 1 {
					t.Fatal("waiting thread was not made inert")
				}
			case "blocked":
				if len(a.threadScheduler.Blocked) != 1 {
					t.Fatal("blocked thread was not made inert")
				}
			}
		})
	}
}
