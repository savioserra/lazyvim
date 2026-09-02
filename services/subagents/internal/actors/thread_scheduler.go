package actors

import (
	"errors"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
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
