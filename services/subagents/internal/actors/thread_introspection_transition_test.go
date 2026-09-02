package actors

import (
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

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
