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
		taskCompletions:     map[string]application.ActorTaskCompleted{"worker-completion": {CompletionKey: "worker-completion", OriginalRequestID: "child-request", DedupeID: "child-dedupe", ChainID: "chain", SourceMutationSequence: 2, Kind: application.BridgeDeliveryPrompt, Terminal: application.BridgeIntentResult{Accepted: true, Completed: true, Result: []byte("worker answer")}, Target: application.CommunicationPeer{StableID: "worker"}}},
		taskCompletionOrder: []string{"worker-completion"},
		threadScheduler:     application.DurableThreadScheduler{ActiveThreadID: "parent", Epoch: 3, ActiveLease: 4},
	}
	thread := application.DurableAgentThread{ThreadID: "parent", Target: application.CommunicationPeer{StableID: "supervisor"}, ChainID: "chain", CompletionKey: "parent-completion", State: application.AgentThreadIntrospecting, WorkerResult: []byte("waiting for worker"), IntrospectionAttempts: 1, ActiveDeliverySequence: 7, Turn: 5, DispatchSchedulerEpoch: 3, DispatchActiveLease: 4, ChildContinuation: &application.DurableChildContinuation{ParentThreadID: "parent", ParentSchedulerEpoch: 3, ParentActiveLease: 4, ParentThreadTurn: 5, ParentDeliverySequence: 7, ChildTaskID: "child-task", ChildRequestID: "child-request", ChildDedupeID: "child-dedupe", ChildChainID: "chain", ChildMutationSequence: 2, ChildTarget: application.CommunicationPeer{StableID: "worker"}, ExpectedKind: application.BridgeDeliveryPrompt}}
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

func TestConsumedChildWithEmptyContinuationResultResumesDeliverable(t *testing.T) {
	now := time.Unix(1_800_000_200, 0)
	completion := application.ActorTaskCompleted{CompletionKey: "child-completion", Terminal: application.BridgeIntentResult{Accepted: true, Completed: true, Result: []byte("exact child answer")}, Target: application.CommunicationPeer{StableID: "worker"}}
	a := &AgentActor{taskCompletions: map[string]application.ActorTaskCompleted{"child-completion": completion}, threadScheduler: application.DurableThreadScheduler{ActiveThreadID: "parent"}}
	thread := application.DurableAgentThread{ThreadID: "parent", State: application.AgentThreadIntrospecting, WorkerResult: nil, ChildContinuation: &application.DurableChildContinuation{Consumed: true, AppliedCompletionKey: "child-completion"}}
	a.threads = map[string]application.DurableAgentThread{"parent": thread}
	a.threadOrder = []string{"parent"}
	action := a.applyThreadIntrospectionClassification(&thread, application.ThreadIntrospectionResult{State: application.ThreadIntrospectionWaiting}, now)
	if action != threadClassificationResume || thread.State != application.AgentThreadResumable || !strings.Contains(string(thread.PendingPrompt), "exact child answer") || !strings.Contains(string(thread.PendingPrompt), "Return the requested parent deliverable") {
		t.Fatalf("consumed child did not resume empty continuation turn: action=%d thread=%#v", action, thread)
	}
}

func TestParentChildWaitRecordedWithExactDispatchIdentity(t *testing.T) {
	targetRef := application.DurableActorRef{AgentID: "worker", Address: "addr", Host: "host", Port: 1, Name: "agent-worker"}
	a := &AgentActor{id: "supervisor", threadScheduler: application.DurableThreadScheduler{ActiveThreadID: "parent", Epoch: 10, ActiveLease: 20}, threads: map[string]application.DurableAgentThread{"parent": {ThreadID: "parent", Target: application.CommunicationPeer{StableID: "supervisor"}, Turn: 30, DispatchSchedulerEpoch: 10, DispatchActiveLease: 20, ActiveDeliverySequence: 40}}}
	message := &application.SendActorTask{Mode: application.BridgeMessageAsk, RequestID: "request-child", DedupeID: "dedupe-child", ChainID: "chain", SourceMutationSequence: 2, ParentContinuation: application.ParentContinuationIdentity{ThreadID: "parent", SchedulerEpoch: 10, ActiveLease: 20, ThreadTurn: 30, DeliverySequence: 40}}
	item := application.DurableActorTaskOutboxItem{TaskID: "task-child", Target: application.CommunicationPeer{StableID: "worker"}, TargetRef: targetRef}
	if !a.recordParentChildWait(message, item, item.TaskID) {
		t.Fatal("exact parent continuation identity rejected")
	}
	wait := a.threads["parent"].ChildContinuation
	if wait == nil || wait.ParentThreadID != "parent" || wait.ParentSchedulerEpoch != 10 || wait.ParentActiveLease != 20 || wait.ParentThreadTurn != 30 || wait.ParentDeliverySequence != 40 || wait.ChildTaskID != "task-child" || wait.ChildRequestID != "request-child" || wait.ChildDedupeID != "dedupe-child" || wait.ChildMutationSequence != 2 || wait.ChildTargetRef != targetRef || wait.ExpectedKind != application.BridgeDeliveryPrompt {
		t.Fatalf("child wait did not retain exact tuple: %#v", wait)
	}
	message.ParentContinuation.ActiveLease = 21
	if a.recordParentChildWait(message, item, item.TaskID) {
		t.Fatal("wrong parent lease accepted")
	}
}

func TestChildContinuationRequiresExactTupleAndConsumption(t *testing.T) {
	a := &AgentActor{id: "supervisor", threadScheduler: application.DurableThreadScheduler{ActiveThreadID: "parent", Epoch: 10, ActiveLease: 20}}
	baseWait := application.DurableChildContinuation{ParentThreadID: "parent", ParentSchedulerEpoch: 10, ParentActiveLease: 20, ParentThreadTurn: 30, ParentDeliverySequence: 40, ChildTaskID: "task-child-1", ChildRequestID: "request-child-1", ChildDedupeID: "dedupe-child-1", ChildChainID: "chain", ChildMutationSequence: 2, ChildTarget: application.CommunicationPeer{StableID: "worker"}, ExpectedKind: application.BridgeDeliveryPrompt}
	thread := application.DurableAgentThread{ThreadID: "parent", Target: application.CommunicationPeer{StableID: "supervisor"}, State: application.AgentThreadWaiting, Turn: 30, DispatchSchedulerEpoch: 10, DispatchActiveLease: 20, ActiveDeliverySequence: 40, ChildContinuation: &baseWait}
	a.threadOrder = []string{"parent"}
	a.threads = map[string]application.DurableAgentThread{"parent": thread}
	completion := application.ActorTaskCompleted{CompletionKey: "completion-child-1", OriginalRequestID: "request-child-1", DedupeID: "dedupe-child-1", ChainID: "chain", SourceMutationSequence: 2, Kind: application.BridgeDeliveryPrompt, Terminal: application.BridgeIntentResult{Accepted: true, Completed: true, Result: []byte("answer 1")}, Target: application.CommunicationPeer{StableID: "worker"}}
	wrong := completion
	wrong.DedupeID = "dedupe-child-2"
	if a.continueParentThreadWithCompletion(wrong) {
		t.Fatal("wrong child completion resumed parent")
	}
	a.threadScheduler.Epoch = 11
	a.threadScheduler.ActiveLease = 21
	if !a.continueParentThreadWithCompletion(completion) {
		t.Fatal("interleaved scheduler advance prevented exact child completion")
	}
	resumed := a.threads["parent"]
	if resumed.ChildContinuation == nil || !resumed.ChildContinuation.Consumed || resumed.ChildContinuation.AppliedCompletionKey != "completion-child-1" {
		t.Fatalf("continuation was not durably marked consumed: %#v", resumed.ChildContinuation)
	}
	if a.continueParentThreadWithCompletion(completion) {
		t.Fatal("consumed continuation replay injected twice")
	}
	staleSameChain := completion
	staleSameChain.CompletionKey = "stale"
	staleSameChain.DedupeID = "dedupe-stale"
	staleSameChain.SourceMutationSequence = 3
	if a.continueParentThreadWithCompletion(staleSameChain) {
		t.Fatal("stale same-chain completion resumed a later turn")
	}
	wrongPersisted := thread
	wrongWait := baseWait
	wrongWait.ParentActiveLease = 99
	wrongPersisted.ChildContinuation = &wrongWait
	if a.childCompletionMatchesWait(wrongPersisted, completion) {
		t.Fatal("wrong persisted parent dispatch identity accepted")
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
