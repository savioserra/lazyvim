package actors

import (
	"context"
	"errors"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

var (
	errThreadIdentityCollision = errors.New("thread identity collision")
	errThreadCapacity          = errors.New("thread capacity exhausted")
)

func (a *AgentActor) ensureThreadScheduler() {
	if a.threads == nil {
		a.threads = make(map[string]application.DurableAgentThread)
	}
	if a.threadScheduler.SchemaVersion == 0 {
		a.threadScheduler = application.DurableThreadScheduler{SchemaVersion: application.DurableThreadSchedulerSchemaV1, AgentID: a.id}
	}
}

func (a *AgentActor) threadNow() time.Time {
	if a.threadClock != nil {
		return a.threadClock()
	}
	return time.Now()
}

func (a *AgentActor) findThreadAdmission(fingerprint application.AgentThreadFingerprint) (application.DurableAgentThread, bool, error) {
	a.ensureThreadScheduler()
	threadID := fingerprint.ThreadID()
	if existing, ok := a.threads[threadID]; ok {
		if existing.Fingerprint().Digest() != fingerprint.Digest() {
			return application.DurableAgentThread{}, false, errThreadIdentityCollision
		}
		return existing, true, nil
	}
	for _, existing := range a.threads {
		if existing.Source.StableID == fingerprint.SourceAgentID && existing.SourceMutationSequence == fingerprint.SourceMutationSequence {
			return application.DurableAgentThread{}, false, errThreadIdentityCollision
		}
	}
	return application.DurableAgentThread{}, false, nil
}

func (a *AgentActor) retainThread(thread application.DurableAgentThread) error {
	a.ensureThreadScheduler()
	if _, exists := a.threads[thread.ThreadID]; exists {
		return errThreadIdentityCollision
	}
	if len(a.threads) >= application.MaxDurableAgentThreads {
		return errThreadCapacity
	}
	a.threads[thread.ThreadID] = thread
	a.threadOrder = append(a.threadOrder, thread.ThreadID)
	a.threadScheduler.Queue = append(a.threadScheduler.Queue, thread.ThreadID)
	return nil
}

// chooseNextThread enforces one model-bearing active thread and the bounded
// two-new-task fairness rule. It mutates only the durable scheduler aggregate;
// the caller must persist the returned decision before dispatching any effect.
func (a *AgentActor) chooseNextThread(now time.Time) (application.DurableAgentThread, bool) {
	a.ensureThreadScheduler()
	if a.threadScheduler.ActiveThreadID != "" {
		return application.DurableAgentThread{}, false
	}
	chooseResumable := a.threadScheduler.NewWorkDeficit >= 2
	var threadID string
	if chooseResumable {
		threadID = a.popEligibleResumable(now)
	}
	if threadID == "" && len(a.threadScheduler.Queue) > 0 {
		threadID = a.threadScheduler.Queue[0]
		a.threadScheduler.Queue = a.threadScheduler.Queue[1:]
		a.threadScheduler.NewWorkDeficit++
	}
	if threadID == "" {
		threadID = a.popEligibleResumable(now)
	}
	if threadID == "" {
		return application.DurableAgentThread{}, false
	}
	thread, exists := a.threads[threadID]
	if !exists {
		return application.DurableAgentThread{}, false
	}
	if thread.State == application.AgentThreadResumable {
		a.threadScheduler.NewWorkDeficit = 0
	}
	a.threadScheduler.Epoch++
	a.threadScheduler.ActiveLease++
	a.threadScheduler.ActiveThreadID = threadID
	thread.State = application.AgentThreadActive
	thread.Turn++
	a.threads[threadID] = thread
	return thread, true
}

func (a *AgentActor) activateThreadDelivery(thread application.DurableAgentThread) (application.BridgeDelivery, error) {
	if a.threadScheduler.ActiveThreadID != thread.ThreadID || thread.ActiveDeliverySequence == 0 || thread.SourceScope == "" || thread.DeliverySourceKey == "" || len(thread.PendingPrompt) == 0 {
		return application.BridgeDelivery{}, errors.New("active thread delivery identity is incomplete")
	}
	delivery := application.BridgeDelivery{Sequence: thread.ActiveDeliverySequence, SchedulerEpoch: a.threadScheduler.Epoch, ActiveLease: a.threadScheduler.ActiveLease, ThreadTurn: thread.Turn, SourceAgentID: thread.Source.StableID, TargetAgentID: thread.Target.StableID, RequestID: thread.RequestID, DedupeID: thread.DedupeID, ChainID: thread.ChainID, ThreadID: thread.ThreadID, Source: thread.Source, Target: thread.Target, Deadline: thread.Deadline, HopLimit: thread.HopLimit - 1, Payload: append([]byte(nil), thread.PendingPrompt...), Policy: application.BridgeDeliveryIdleElseFollowUp, Kind: application.BridgeDeliveryPrompt, SourceScope: thread.SourceScope, CompletionKey: thread.CompletionKey, DeliveryBackend: thread.DeliveryBackend}
	if !delivery.AckIdentityComplete() {
		return application.BridgeDelivery{}, errors.New("active thread acknowledgement identity is incomplete")
	}
	thread.State = application.AgentThreadAwaitingAgentSettled
	thread.EventCursor++
	thread.Events = append(thread.Events, application.DurableThreadEvent{Sequence: thread.EventCursor, Kind: "dispatched", At: a.threadNow(), DeliverySequence: delivery.Sequence, Digest: thread.Fingerprint().Digest()})
	a.threads[thread.ThreadID] = thread
	a.bridgeDeliveries = append(a.bridgeDeliveries, delivery)
	a.deliverySources[delivery.Sequence] = thread.DeliverySourceKey
	return delivery, nil
}

func (a *AgentActor) scheduleThread(ctx *actor.ReceiveContext) {
	if a.durableFailed != nil {
		return
	}
	if a.durablePending != nil {
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &scheduleThreadTick{}, ctx.Self(), 10*time.Millisecond)
		return
	}
	now := a.threadNow()
	old := a.durableState()
	thread, selected := a.chooseNextThread(now)
	if !selected {
		if delay, ok := a.nextResumableDelay(now); ok {
			_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &scheduleThreadTick{}, ctx.Self(), max(delay, time.Millisecond))
		}
		return
	}
	oldSequence := thread.ActiveDeliverySequence
	if oldSequence == 0 || oldSequence <= a.ackCursor {
		a.bridgeSequence++
		thread.ActiveDeliverySequence = a.bridgeSequence
		a.threads[thread.ThreadID] = thread
	}
	if oldSequence != thread.ActiveDeliverySequence {
		if pid, ok := a.taskSources[oldSequence]; ok {
			a.taskSources[thread.ActiveDeliverySequence] = pid
			delete(a.taskSources, oldSequence)
		}
		if ref, ok := a.durableTaskSources[oldSequence]; ok {
			a.durableTaskSources[thread.ActiveDeliverySequence] = ref
			delete(a.durableTaskSources, oldSequence)
		}
		if scope := a.mutationScopes[thread.DeliverySourceKey]; scope != nil {
			record := scope.dedupe[thread.DedupeID]
			record.sequence = thread.ActiveDeliverySequence
			scope.dedupe[thread.DedupeID] = record
		}
	}
	if _, err := a.activateThreadDelivery(thread); err != nil {
		a.restoreDurableState(old)
		return
	}
	_ = a.beginDurablePersist(ctx, &pendingDurableReceipt{old: old})
}

func (a *AgentActor) nextResumableDelay(now time.Time) (time.Duration, bool) {
	var earliest time.Time
	for _, threadID := range a.threadScheduler.Resumable {
		thread, ok := a.threads[threadID]
		if !ok || thread.State != application.AgentThreadResumable {
			continue
		}
		if thread.NextAttempt.IsZero() || !now.Before(thread.NextAttempt) {
			return 0, true
		}
		if earliest.IsZero() || thread.NextAttempt.Before(earliest) {
			earliest = thread.NextAttempt
		}
	}
	if earliest.IsZero() {
		return 0, false
	}
	return earliest.Sub(now), true
}

func (a *AgentActor) popEligibleResumable(now time.Time) string {
	for index, threadID := range a.threadScheduler.Resumable {
		thread, ok := a.threads[threadID]
		if !ok || thread.State != application.AgentThreadResumable || (!thread.NextAttempt.IsZero() && now.Before(thread.NextAttempt)) {
			continue
		}
		a.threadScheduler.Resumable = append(a.threadScheduler.Resumable[:index], a.threadScheduler.Resumable[index+1:]...)
		return threadID
	}
	return ""
}
