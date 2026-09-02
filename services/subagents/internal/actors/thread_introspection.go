package actors

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

const maxThreadIntrospectionAttempts = 3

func (a *AgentActor) beginThreadIntrospection(ctx *actor.ReceiveContext, threadID string) {
	if threadID == "" || a.durableFailed != nil {
		return
	}
	if a.durablePending != nil {
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &beginThreadIntrospection{threadID: threadID}, ctx.Self(), 10*time.Millisecond)
		return
	}
	thread, exists := a.threads[threadID]
	if !exists || a.threadScheduler.ActiveThreadID != threadID {
		return
	}
	if thread.State == application.AgentThreadIntrospecting && thread.IntrospectionAttemptID != "" {
		a.startThreadIntrospection(ctx, a.threadIntrospectionAttempt(thread))
		return
	}
	if thread.State != application.AgentThreadSettled {
		return
	}
	now := a.threadNow()
	if !thread.NextAttempt.IsZero() && now.Before(thread.NextAttempt) {
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &beginThreadIntrospection{threadID: threadID}, ctx.Self(), max(thread.NextAttempt.Sub(now), time.Millisecond))
		return
	}
	if thread.IntrospectionAttempts >= maxThreadIntrospectionAttempts {
		a.finishExhaustedThread(ctx, thread)
		return
	}
	old := a.durableState()
	thread.IntrospectionAttempts++
	thread.IntrospectionAttemptID = threadAttemptID(thread, a.threadScheduler, thread.IntrospectionAttempts)
	thread.State = application.AgentThreadIntrospecting
	thread.NextAttempt = time.Time{}
	appendThreadEvent(&thread, application.DurableThreadEvent{Kind: "introspection_started", At: now, DeliverySequence: thread.ActiveDeliverySequence, Digest: sha256.Sum256([]byte(thread.IntrospectionAttemptID))})
	a.threads[threadID] = thread
	attempt := a.threadIntrospectionAttempt(thread)
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: old, introspectionStart: &attempt}) {
		return
	}
	a.startThreadIntrospection(ctx, attempt)
}

func (a *AgentActor) threadIntrospectionAttempt(thread application.DurableAgentThread) application.ThreadIntrospectionAttempt {
	bridgeRunCounter := uint64(0)
	if ack, ok := a.committedAcks[thread.ActiveDeliverySequence]; ok {
		bridgeRunCounter = ack.BridgeRunCounter
	}
	return application.ThreadIntrospectionAttempt{AgentID: a.id, RuntimeID: a.hostedPiRuntime.RuntimeID, Incarnation: a.hostedPiRuntime.Incarnation, ThreadID: thread.ThreadID, SchedulerEpoch: a.threadScheduler.Epoch, ActiveLease: a.threadScheduler.ActiveLease, ThreadTurn: thread.Turn, DeliverySequence: thread.ActiveDeliverySequence, BridgeRunCounter: bridgeRunCounter, AttemptID: thread.IntrospectionAttemptID, Input: application.ThreadIntrospectionInput{TaskPrompt: string(thread.TaskPrompt), WorkerResult: string(thread.WorkerResult), Checkpoint: thread.Checkpoint}, Timeout: 2 * time.Minute}
}

func (a *AgentActor) startThreadIntrospection(ctx *actor.ReceiveContext, attempt application.ThreadIntrospectionAttempt) {
	self := ctx.Self()
	runner := a.introspectionRunner
	if runner == nil {
		_ = self.Tell(context.WithoutCancel(ctx.Context()), self, &threadIntrospectionFinished{outcome: application.ThreadIntrospectionOutcome{Attempt: attempt, FailureClass: "runner_unavailable"}})
		return
	}
	parent := context.WithoutCancel(ctx.Context())
	go func() {
		runCtx, cancel := context.WithTimeout(parent, attempt.Timeout)
		defer cancel()
		result, err := runner.Run(runCtx, attempt.Input)
		outcome := application.ThreadIntrospectionOutcome{Attempt: attempt, Result: result}
		if err != nil {
			outcome.FailureClass = "runner_failed"
		}
		_ = self.Tell(parent, self, &threadIntrospectionFinished{outcome: outcome})
	}()
}

func (a *AgentActor) finishThreadIntrospection(ctx *actor.ReceiveContext, outcome application.ThreadIntrospectionOutcome) {
	if a.durableFailed != nil {
		return
	}
	if a.durablePending != nil {
		copy := outcome
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &threadIntrospectionFinished{outcome: copy}, ctx.Self(), 10*time.Millisecond)
		return
	}
	thread, exists := a.threads[outcome.Attempt.ThreadID]
	if !exists || thread.State != application.AgentThreadIntrospecting || thread.IntrospectionAttemptID != outcome.Attempt.AttemptID || a.threadScheduler.ActiveThreadID != thread.ThreadID || outcome.Attempt.SchedulerEpoch != a.threadScheduler.Epoch || outcome.Attempt.ActiveLease != a.threadScheduler.ActiveLease || outcome.Attempt.ThreadTurn != thread.Turn || outcome.Attempt.DeliverySequence != thread.ActiveDeliverySequence {
		return
	}
	old := a.durableState()
	now := a.threadNow()
	if outcome.FailureClass != "" {
		thread.FailureClass = outcome.FailureClass
		appendThreadEvent(&thread, application.DurableThreadEvent{Kind: "introspection_failed", At: now, DeliverySequence: thread.ActiveDeliverySequence, Reason: outcome.FailureClass})
		if thread.IntrospectionAttempts >= maxThreadIntrospectionAttempts {
			thread.State = application.AgentThreadExhausted
			a.threads[thread.ThreadID] = thread
			a.completeThreadTerminal(thread, application.BridgeIntentResult{Accepted: true, Reason: "thread introspection exhausted"})
			a.persistThreadTransition(ctx, &pendingDurableReceipt{old: old, threadSchedule: true})
			return
		}
		thread.State = application.AgentThreadSettled
		thread.NextAttempt = now.Add(threadIntrospectionBackoff(thread.IntrospectionAttempts))
		a.threads[thread.ThreadID] = thread
		delay := thread.NextAttempt.Sub(now)
		a.persistThreadTransition(ctx, &pendingDurableReceipt{old: old, introspectionRetryThread: thread.ThreadID, introspectionRetryDelay: delay})
		return
	}
	encoded, err := json.Marshal(outcome.Result)
	if err != nil {
		outcome.FailureClass = "result_encoding_failed"
		a.finishThreadIntrospection(ctx, outcome)
		return
	}
	thread.IntrospectionResult = outcome.Result
	thread.IntrospectionDigest = sha256.Sum256(encoded)
	thread.Checkpoint = outcome.Result.Checkpoint
	thread.CheckpointDigest = sha256.Sum256([]byte(thread.Checkpoint))
	thread.FailureClass = ""
	appendThreadEvent(&thread, application.DurableThreadEvent{Kind: "introspection_committed", At: now, DeliverySequence: thread.ActiveDeliverySequence, Digest: thread.IntrospectionDigest})
	action := a.applyThreadIntrospectionClassification(&thread, outcome.Result, now)
	a.threads[thread.ThreadID] = thread
	switch action {
	case threadClassificationComplete:
		a.completeThreadTerminal(thread, application.BridgeIntentResult{Accepted: true, Completed: true, Result: append([]byte(nil), thread.WorkerResult...)})
		a.persistThreadTransition(ctx, &pendingDurableReceipt{old: old, threadSchedule: true})
	case threadClassificationResume:
		a.persistThreadTransition(ctx, &pendingDurableReceipt{old: old, threadSchedule: true})
	case threadClassificationInert:
		a.persistThreadTransition(ctx, &pendingDurableReceipt{old: old})
	}

}

type threadClassificationAction uint8

const (
	threadClassificationInert threadClassificationAction = iota
	threadClassificationResume
	threadClassificationComplete
)

func (a *AgentActor) applyThreadIntrospectionClassification(thread *application.DurableAgentThread, result application.ThreadIntrospectionResult, now time.Time) threadClassificationAction {
	switch result.State {
	case application.ThreadIntrospectionCompleted:
		if !workerResultContainsDeliverable(thread.WorkerResult) {
			thread.State = application.AgentThreadResumable
			thread.ResumeAttempts++
			thread.PendingPrompt = []byte("Return the requested deliverable directly in this thread. Do not reply with an acknowledgement, promise, or sent-elsewhere pointer.")
			thread.NextAttempt = now.Add(threadIntrospectionBackoff(thread.IntrospectionAttempts))
			appendThreadEvent(thread, application.DurableThreadEvent{Kind: "completion_pointer_rejected", At: now, DeliverySequence: thread.ActiveDeliverySequence, Reason: "deliverable_missing"})
			a.threadScheduler.ActiveThreadID = ""
			a.threadScheduler.Resumable = append(a.threadScheduler.Resumable, thread.ThreadID)
			return threadClassificationResume
		}
		thread.State = application.AgentThreadCompleted
		a.threadScheduler.ActiveThreadID = ""
		return threadClassificationComplete
	case application.ThreadIntrospectionContinue:
		thread.State = application.AgentThreadResumable
		thread.ResumeAttempts++
		thread.PendingPrompt = []byte(result.NextPrompt)
		thread.NextAttempt = now.Add(threadIntrospectionBackoff(thread.IntrospectionAttempts))
		a.threadScheduler.ActiveThreadID = ""
		a.threadScheduler.Resumable = append(a.threadScheduler.Resumable, thread.ThreadID)
		return threadClassificationResume
	case application.ThreadIntrospectionWaiting:
		thread.State = application.AgentThreadWaiting
		a.threadScheduler.ActiveThreadID = ""
		a.threadScheduler.Waiting = append(a.threadScheduler.Waiting, thread.ThreadID)
		return threadClassificationInert
	case application.ThreadIntrospectionBlocked:
		thread.State = application.AgentThreadBlocked
		a.threadScheduler.ActiveThreadID = ""
		a.threadScheduler.Blocked = append(a.threadScheduler.Blocked, thread.ThreadID)
		return threadClassificationInert
	default:
		return threadClassificationInert
	}
}

func (a *AgentActor) finishExhaustedThread(ctx *actor.ReceiveContext, thread application.DurableAgentThread) {
	old := a.durableState()
	thread.State = application.AgentThreadExhausted
	thread.FailureClass = "introspection_exhausted"
	appendThreadEvent(&thread, application.DurableThreadEvent{Kind: "introspection_exhausted", At: a.threadNow(), DeliverySequence: thread.ActiveDeliverySequence, Reason: thread.FailureClass})
	a.threads[thread.ThreadID] = thread
	a.completeThreadTerminal(thread, application.BridgeIntentResult{Accepted: true, Reason: "thread introspection exhausted"})
	a.persistThreadTransition(ctx, &pendingDurableReceipt{old: old, threadSchedule: true})
}

func (a *AgentActor) persistThreadTransition(ctx *actor.ReceiveContext, pending *pendingDurableReceipt) {
	if a.beginDurablePersist(ctx, pending) {
		return
	}
	a.scheduleCompletionRetry(ctx)
	if pending.introspectionRetryThread != "" {
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &beginThreadIntrospection{threadID: pending.introspectionRetryThread}, ctx.Self(), max(pending.introspectionRetryDelay, time.Millisecond))
	}
	if pending.threadSchedule {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), ctx.Self(), &scheduleThreadTick{})
	}
}

func (a *AgentActor) completeThreadTerminal(thread application.DurableAgentThread, result application.BridgeIntentResult) {
	key := thread.DeliverySourceKey
	if scope := a.mutationScopes[key]; scope != nil {
		if record, ok := scope.dedupe[thread.DedupeID]; ok {
			mutation := scope.results[record.mutationSequence]
			mutation.pending, mutation.result = false, result
			scope.results[record.mutationSequence] = mutation
			scope.completed++
			delete(scope.dedupe, thread.DedupeID)
			delete(scope.chains, record.chainID)
			retireMutationResults(scope)
		}
	}
	completed := application.ActorTaskCompleted{CompletionKey: thread.CompletionKey, ThreadID: thread.ThreadID, OriginalRequestID: thread.RequestID, DedupeID: thread.DedupeID, ChainID: thread.ChainID, SourceMutationSequence: thread.SourceMutationSequence, Terminal: result, Source: thread.Source, Target: thread.Target, Kind: application.BridgeDeliveryPrompt}
	a.retainPendingCompletionTell(thread.CompletionKey, thread.SourceRef, completed)
	delete(a.taskSources, thread.ActiveDeliverySequence)
	delete(a.durableTaskSources, thread.ActiveDeliverySequence)
	a.threadScheduler.ActiveThreadID = ""
}

func appendThreadEvent(thread *application.DurableAgentThread, event application.DurableThreadEvent) {
	thread.EventCursor++
	event.Sequence = thread.EventCursor
	thread.Events = append(thread.Events, event)
	if len(thread.Events) > application.MaxDurableThreadEvents {
		thread.Events = append([]application.DurableThreadEvent(nil), thread.Events[len(thread.Events)-application.MaxDurableThreadEvents:]...)
	}
}

func threadAttemptID(thread application.DurableAgentThread, scheduler application.DurableThreadScheduler, attempt uint32) string {
	value := thread.ThreadID + "\x00" + strconv.FormatUint(thread.Turn, 10) + "\x00" + strconv.FormatUint(scheduler.Epoch, 10) + "\x00" + strconv.FormatUint(scheduler.ActiveLease, 10) + "\x00" + strconv.FormatUint(uint64(attempt), 10)
	digest := sha256.Sum256([]byte(value))
	return hex.EncodeToString(digest[:16])
}

func workerResultContainsDeliverable(result []byte) bool {
	value := strings.ToLower(strings.TrimSpace(string(result)))
	if value == "" {
		return false
	}
	if len(value) <= 64 {
		switch value {
		case "ok", "done", "completed", "ack", "acknowledged", "sent", "sent elsewhere", "see previous message", "see my other message":
			return false
		}
	}
	if len(value) <= 512 {
		for _, marker := range []string{"sent to the client", "sent to client", "sent elsewhere", "provided elsewhere", "delivered elsewhere", "sent out of band", "see the other message", "reconnaissance sent"} {
			if strings.Contains(value, marker) {
				return false
			}
		}
	}
	return true
}

func threadIntrospectionBackoff(attempt uint32) time.Duration {
	delay := time.Second << min(attempt-1, 9)
	return min(delay, 5*time.Minute)
}
