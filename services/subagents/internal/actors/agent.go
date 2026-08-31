package actors

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

const (
	maxCommandResults        = 1024
	maxCommandIdentities     = 4096
	maxRevokedGenerations    = 4096
	projectionRetry          = 10 * time.Millisecond
	bridgeLeaseDuration      = time.Second
	maxBridgeItems           = 256
	maxRecentMutationResults = 1024
	maxBridgePayloadBytes    = 16 * 1024
	maxSourceOutboxItems     = 256
	maxTargetTaskQueueItems  = 256
	maxAckGapBuffer          = 64
	maxCommittedAcks         = 64
	maxCompletionTells       = 64
	maxCompletionAttempts    = 8
	maxScopeTokens           = 4096
	scopeTokenBytes          = 16
	maxScopeTokenLength      = 64
	outboxBaseRetryDelay     = 50 * time.Millisecond
	outboxMaxRetryDelay      = 2 * time.Second
	taskCreditLease          = 5 * time.Second
	taskRetryDelay           = 50 * time.Millisecond
)

type projectionSubscribed struct{ sessionID, generationID string }
type projectionSubscribedObserved struct{}
type projectionEvent struct {
	event application.AgentProjectionEvent
}
type closeProjection struct{}
type retryProjectionPubSub struct{}
type retrySourceOutbox struct{}
type retryCompletionTells struct{}
type retryOutboxSchedule struct{}

// actorRefResolved is the async continuation of resolveActorRefAsync: the
// background lookup reports its result back to the agent mailbox so Receive
// paths never block on actor-plane resolution.
type actorRefResolved struct {
	address string
	pid     *actor.PID
}

type ackBurstReceipt struct {
	response chan<- application.BridgeDeliveryAckResult
	result   application.BridgeDeliveryAckResult
	commits  []ackCommitEffect
}

type ackCommitEffect struct {
	scopeKey, dedupeID string
	askCompletion      chan<- application.BridgeIntentResult
	askResult          application.BridgeIntentResult
	taskReplyTo        *actor.PID
	taskCompletion     *application.ActorTaskCompleted
}

type taskCreditReservation struct {
	credit  application.TaskCredit
	source  string
	replyTo *actor.PID
}
type retryProjectionClose struct{ sessionID, generationID string }
type restoreDurableTimers struct{}
type projectionDrop struct {
	message application.DropSession
}

type projectionLifecycle struct {
	pid           *actor.PID
	subscribed    bool
	closing       bool
	startSequence uint64
	requesters    []chan<- application.OperationResult
	drops         []projectionDrop
	closes        []chan<- application.OperationResult
}

type attachment struct {
	principal    string
	handle       string
	fence        uint64
	capabilities map[string]struct{}
}
type commandRecord struct {
	digest [32]byte
	result *application.CommandResult
}
type bridgeDedupeRecord struct {
	sequence         uint64
	mutationSequence uint64
	chainID          string
}
type mutationRecord struct {
	digest   [32]byte
	pending  bool
	result   application.BridgeIntentResult
	dedupeID string
	chainID  string
}
type pendingDurableReceipt struct {
	correlation                 uint64
	sender                      *actor.PID
	operation                   chan<- application.OperationResult
	operationResult             *application.OperationResult
	old                         application.DurableAgentState
	intent                      *application.BridgeIntentResult
	intentCompletion            chan<- application.BridgeIntentResult
	ackBurst                    *ackBurstReceipt
	taskCreditGrant             *application.TaskCreditGranted
	taskAccepted                *application.ActorTaskAccepted
	sourceCreditTarget          *actor.PID
	sourceCreditItem            *application.DurableActorTaskOutboxItem
	taskCompletionPublish       *application.ActorTaskCompleted
	targetTaskCommitted         *application.TargetTaskCommitted
	attach                      *application.AttachResult
	attachCompletion            chan<- application.AttachResult
	bridge                      *application.BridgeResult
	bridgeCompletion            chan<- application.BridgeResult
	timeoutScope, timeoutDedupe string
	timeout                     time.Duration
	askScope, askDedupe         string
	askCompletion               chan<- application.BridgeIntentResult
	askResult                   *application.BridgeIntentResult
	removeAskOnFailure          bool
	retryTimeout                bool
	// runtimeStateForward carries the incarnation-retirement transition: the
	// registry projection forward and the bounded retry of the state change
	// fire only after the retirement batch durably commits.
	runtimeStateForward    *application.HostedPiRuntimeStateChanged
	runtimeRollbackBinding *application.HostedPiRuntimeBinding
	// liveTaskSources snapshots the in-memory delivery-to-source PID map before
	// a mutation retires deliveries: live PIDs are deliberately absent from the
	// durable state, so a persistence rollback restores them from here.
	liveTaskSources map[uint64]*actor.PID
	drop            *projectionDrop
	rollingBack     bool
	persistErr      error
}
type pendingBridgeAsk struct {
	completion chan<- application.BridgeIntentResult
}
type mutationScope struct {
	sessionID, generationID, principal string
	fence, incarnation                 uint64
	// token is the opaque server-issued scope token that names this scope on
	// serialized surfaces (deliveries and acknowledgements). The internal key
	// stays private to owner state.
	token     string
	highWater uint64
	results   map[uint64]mutationRecord
	order     []uint64
	completed int
	dedupe    map[string]bridgeDedupeRecord
	chains    map[string]struct{}
	asks      map[string]pendingBridgeAsk
}

// AgentActor is globally reusable and independent of all Pi session actors. Its
// mailbox defines the deterministic total order for commands from every
// attached session. Hosted-owned mutation receipts are released only after the
// asynchronous persistence actor confirms the owner-private operational state.
type AgentActor struct {
	id               string
	authorityBinding application.AuthorityBinding
	hostedPiRuntime  application.HostedPiRuntimeBinding
	retention        string
	recovery         string
	allowed          map[string]struct{}
	attachments      map[string]attachment
	revoked          map[string]struct{}
	fence            uint64
	revision         uint64
	commandSequence  uint64
	commandResults   map[string]commandRecord
	commandOrder     []string

	// projections tracks acknowledgement state and child PIDs only. GoAkt
	// TopicActor remains the sole subscriber registry and fanout authority.
	projections                 map[string]*projectionLifecycle
	projectionSubscriptionDelay time.Duration
	projectionMailbox           func() actor.Mailbox

	registryPID            *actor.PID
	runtimePID             *actor.PID
	runtimeFailure         string
	bridgeSession          string
	bridgeGeneration       string
	bridgePrincipal        string
	bridgeHandle           string
	bridgePiSession        string
	bridgeFence            uint64
	bridgeLeaseToken       uint64
	bridgeDeclaredReady    bool
	bridgeSequence         uint64
	bridgeEvents           []application.BridgeEvent
	bridgeDeliveries       []application.BridgeDelivery
	deliverySources        map[uint64]string
	taskSources            map[uint64]*actor.PID
	durableTaskSources     map[uint64]application.DurableActorRef
	resolvedRefs           map[string]*actor.PID
	resolvingRefs          map[string]struct{}
	scopeTokens            map[string]string
	completionTellPending  map[string]application.DurablePendingCompletion
	completionTellOrder    []string
	ackGaps                map[uint64]application.BridgeDeliveryAck
	committedAcks          map[uint64]application.DurableBridgeAckRecord
	committedAckOrder      []uint64
	ackCursor              uint64
	taskCompletions        map[string]application.ActorTaskCompleted
	taskCompletionOrder    []string
	sourceTaskHistory      map[string]application.ActorTaskCompleted
	sourceTaskHistoryOrder []string
	sourceOutbox           map[string]application.DurableActorTaskOutboxItem
	sourceOutboxOrder      []string
	taskCreditEpoch        uint64
	taskCreditReservations map[string]taskCreditReservation
	mutationScopes         map[string]*mutationScope
	persistencePID         *actor.PID
	persistenceSupervisor  *actor.PID
	durableRecord          *application.DurableHostedRecord
	durableCorrelation     uint64
	durablePending         *pendingDurableReceipt
	durableFailed          error
}

func NewAgentActor(registration *application.RegisterAgent, registry ...*actor.PID) *AgentActor {
	allowed := make(map[string]struct{}, len(registration.AllowedCapability))
	for _, capability := range registration.AllowedCapability {
		allowed[capability] = struct{}{}
	}
	metadataBinding := registration.HostedPiRuntime
	metadataBinding.DisplayName = registration.DisplayName
	metadataBinding.Role = registration.Role
	value := &AgentActor{id: registration.AgentID, authorityBinding: registration.AuthorityBinding, hostedPiRuntime: metadataBinding, retention: registration.Retention, recovery: registration.Recovery, allowed: allowed, attachments: make(map[string]attachment), revoked: make(map[string]struct{}), revision: 1, commandResults: make(map[string]commandRecord), projections: make(map[string]*projectionLifecycle), deliverySources: make(map[uint64]string), taskSources: make(map[uint64]*actor.PID), durableTaskSources: make(map[uint64]application.DurableActorRef), resolvedRefs: make(map[string]*actor.PID), resolvingRefs: make(map[string]struct{}), scopeTokens: make(map[string]string), completionTellPending: make(map[string]application.DurablePendingCompletion), ackGaps: make(map[uint64]application.BridgeDeliveryAck), committedAcks: make(map[uint64]application.DurableBridgeAckRecord), taskCompletions: make(map[string]application.ActorTaskCompleted), sourceTaskHistory: make(map[string]application.ActorTaskCompleted), sourceOutbox: make(map[string]application.DurableActorTaskOutboxItem), taskCreditReservations: make(map[string]taskCreditReservation), mutationScopes: make(map[string]*mutationScope), persistencePID: registration.PersistencePID, persistenceSupervisor: registration.PersistenceSupervisor, durableRecord: registration.DurableRecord}
	if registration.DurableRecord != nil {
		value.restoreDurableState(registration.DurableRecord.AgentState)
		if registration.AdoptedProcess != nil {
			// Readiness is a live fenced lease, never a restart-persistent fact.
			// The exact bridge must reconnect after daemon adoption.
			value.bridgeDeclaredReady = false
			value.hostedPiRuntime.BridgeReady = false
		}
	}
	if len(registry) > 0 {
		value.registryPID = registry[0]
	}
	return value
}
func (*AgentActor) PreStart(*actor.Context) error { return nil }
func (*AgentActor) PostStop(*actor.Context) error { return nil }
func (a *AgentActor) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *actor.PostStart:
		if a.durableRecord != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), ctx.Self(), &restoreDurableTimers{})
		}
	case *restoreDurableTimers:
		a.restoreDurableTimers(ctx)
	case *application.RemoteAttachAgent:
		a.remoteAttach(ctx, message)
	case *application.AttachAgent:
		if a.isRevoked(message.SessionID, message.GenerationID) {
			respondAttach(ctx, message.Result, &application.AttachResult{Reason: "session generation revoked"})
			return
		}
		capabilities := make(map[string]struct{}, len(message.RequestedCapabilities))
		for _, capability := range message.RequestedCapabilities {
			if _, ok := a.allowed[capability]; !ok {
				respondAttach(ctx, message.Result, &application.AttachResult{Reason: "capability denied"})
				return
			}
			capabilities[capability] = struct{}{}
		}
		if a.durablePending != nil || a.durableFailed != nil {
			respondAttach(ctx, message.Result, &application.AttachResult{Reason: "durable persistence is busy"})
			return
		}
		old := a.durableState()
		key := generationKey(message.SessionID, message.GenerationID)
		if current, exists := a.attachments[key]; exists {
			a.pruneRevokedMutationScope(message.SessionID, message.GenerationID, current.principal, current.fence)
		}
		a.fence++
		a.attachments[key] = attachment{principal: message.Principal, handle: message.IssuedHandle, fence: a.fence, capabilities: capabilities}
		a.revision++
		result := application.AttachResult{Completed: true, Handle: message.IssuedHandle, Fence: a.fence}
		if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: old, attach: &result, attachCompletion: message.Result}) {
			return
		}
		respondAttach(ctx, message.Result, &result)
	case *application.ReattachAgent:
		if a.isRevoked(message.SessionID, message.GenerationID) {
			respondAttach(ctx, message.Result, &application.AttachResult{Reason: "session generation revoked"})
			return
		}
		if a.durablePending != nil || a.durableFailed != nil {
			respondAttach(ctx, message.Result, &application.AttachResult{Reason: "durable persistence is busy"})
			return
		}
		key := generationKey(message.SessionID, message.GenerationID)
		current, ok := a.attachments[key]
		if !ok || current.principal != message.Principal || current.handle != message.PreviousHandle || current.fence != message.PreviousFence {
			respondAttach(ctx, message.Result, &application.AttachResult{Reason: "stale agent fence"})
			return
		}
		old := a.durableState()
		a.pruneRevokedMutationScope(message.SessionID, message.GenerationID, current.principal, current.fence)
		a.fence++
		current.fence, current.handle = a.fence, message.IssuedHandle
		a.attachments[key] = current
		a.revision++
		result := application.AttachResult{Completed: true, Handle: current.handle, Fence: current.fence}
		if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: old, attach: &result, attachCompletion: message.Result}) {
			return
		}
		respondAttach(ctx, message.Result, &result)
	case *application.DetachAgent:
		if !a.validHandle(message.SessionID, message.GenerationID, message.Principal, message.Handle, message.Fence, "") {
			respondOperation(ctx, message.Result, &application.OperationResult{Reason: "unauthorized or stale agent handle"})
			return
		}
		if a.durablePending != nil || a.durableFailed != nil {
			respondOperation(ctx, message.Result, &application.OperationResult{Reason: "durable persistence is busy"})
			return
		}
		old := a.durableState()
		a.pruneRevokedMutationScope(message.SessionID, message.GenerationID, message.Principal, message.Fence)
		delete(a.attachments, generationKey(message.SessionID, message.GenerationID))
		a.revision++
		result := application.OperationResult{Completed: true, Revision: a.revision}
		if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: old, operation: message.Result, operationResult: &result}) {
			return
		}
		respondOperation(ctx, message.Result, &result)
	case *application.SubscribeAgent:
		a.subscribe(ctx, message)
	case *application.UnsubscribeAgent:
		a.unsubscribe(ctx, message)
	case *projectionSubscribed:
		a.subscriptionAck(ctx, message)
	case *retryProjectionClose:
		a.retryProjectionClose(ctx, message)
	case *actor.Terminated:
		if a.runtimePID != nil && message.ActorPath().Name() == a.runtimePID.Name() {
			a.runtimePID = nil
			a.runtimeFailure = "hosted runtime actor terminated"
			a.hostedPiRuntime.State = application.HostedPiRuntimeDegraded
			a.hostedPiRuntime.BridgeReady = false
			a.revision++
		} else {
			a.projectionTerminated(ctx, message)
		}
	case *application.AgentCommand:
		a.command(ctx, message)
	case *application.BindHostedPiRuntimeActor:
		a.runtimePID = message.PID
		if message.PID != nil {
			ctx.Watch(message.PID)
		}
	case *application.HostedPiRuntimeStatus:
		copy := a.hostedPiRuntime
		// Health and status reports derive bridge readiness from the live
		// binding, never from a persisted flag: a wiped or stale binding flag
		// cannot report ready while no live fenced bridge session exists.
		copy.BridgeReady = copy.BridgeReady && a.bridgeDeclaredReady
		ctx.Response(&copy)
	case *application.HostedPiRuntimeFailureStatus:
		ctx.Response(&application.HostedPiRuntimeFailure{Reason: a.runtimeFailure})
	case *application.StartHostedPiRuntime:
		if a.runtimePID != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), a.runtimePID, message)
		}
	case *application.StopHostedPiRuntime:
		if a.runtimePID != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), a.runtimePID, message)
		} else {
			a.runtimeFailure = "hosted runtime actor unavailable during stop"
			a.hostedPiRuntime.State = application.HostedPiRuntimeDegraded
			a.hostedPiRuntime.BridgeReady = false
			a.revision++
			respondOperation(ctx, message.Accepted, &application.OperationResult{Reason: a.runtimeFailure})
		}
	case *application.HostedPiBridgeReadiness:
		if a.runtimePID != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), a.runtimePID, message)
		}
	case *application.HostedPiRuntimeStateChanged:
		binding := message.Binding
		if binding.RuntimeID != a.hostedPiRuntime.RuntimeID || !validRuntimeProjectionAdvance(a.hostedPiRuntime, binding) {
			return
		}
		if binding.Incarnation > a.hostedPiRuntime.Incarnation {
			a.incarnationRetired(ctx, message, binding)
			return
		}
		a.applyRuntimeBinding(message, binding)
		a.revision++
		if a.registryPID != nil {
			copy := *message
			copy.Binding = binding
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), a.registryPID, &copy)
		}
	case *application.BridgeConnect:
		a.bridgeConnect(ctx, message)
	case *application.BridgeLifecycle:
		a.bridgeLifecycle(ctx, message)
	case *application.BridgeHeartbeat:
		a.bridgeHeartbeat(ctx, message)
	case *application.HostedPiBridgeLeaseExpired:
		a.bridgeLeaseExpired(ctx, message)
	case *application.RemoteBridgeIntent:
		var completion chan application.BridgeIntentResult
		if message.ReplyTopic != "" && message.Mode == application.BridgeMessageAsk {
			completion = make(chan application.BridgeIntentResult, 1)
			system := ctx.ActorSystem()
			self := ctx.Self()
			go func() {
				select {
				case result := <-completion:
					publishActorReply(system, self, message, result)
				case <-time.After(max(time.Until(message.Deadline), time.Millisecond)):
				}
			}()
		}
		a.bridgeIntent(ctx, &application.BridgeIntent{SessionID: message.SessionID, GenerationID: message.GenerationID, Principal: message.Principal, Handle: message.Handle, SourceAgentID: message.SourceAgentID, TargetAgentID: message.TargetAgentID, RequestID: message.RequestID, RequiredCapability: message.RequiredCapability, DedupeID: message.DedupeID, ChainID: message.ChainID, Fence: message.Fence, SourceMutationSequence: message.SourceMutationSequence, Deadline: message.Deadline, HopLimit: message.HopLimit, Mode: message.Mode, Payload: message.Payload, Completion: completion})
	case *application.SendActorTask:
		a.sendActorTask(ctx, message)
	case *application.RequestTaskCredit:
		a.requestTaskCredit(ctx, message)
	case *application.TaskCreditGranted:
		a.taskCreditGranted(ctx, message)
	case *application.TaskBackpressured:
		a.taskBackpressured(ctx, message)
	case *application.ActorTask:
		a.actorTask(ctx, message)
	case *application.ActorTaskAccepted:
		a.actorTaskAccepted(ctx, message)
	case *retrySourceOutbox:
		a.retrySourceOutbox(ctx)
	case *retryCompletionTells:
		a.retryCompletionTells(ctx)
	case *retryOutboxSchedule:
		a.scheduleOutboxRetry(ctx)
	case *actorRefResolved:
		a.actorRefResolved(ctx, message)
	case *application.ActorTaskCompleted:
		a.actorTaskCompleted(ctx, message)
	case *application.DrainReceivedTaskCompletions:
		a.drainTaskCompletions(message)
	case *application.BridgeIntent:
		a.bridgeIntent(ctx, message)
	case *application.BridgeControl:
		a.bridgeControl(ctx, message)
	case *application.BridgeDeliveryAck:
		a.bridgeDeliveryAck(ctx, message)
	case *application.BridgeIntentTimeout:
		a.bridgeIntentTimeout(ctx, message)
	case *application.DurableHostedStatePersisted:
		a.durablePersisted(ctx, message)
	case *application.DurableBarrier:
		a.durableBarrier(ctx)
	case *application.BridgeReplace:
		a.bridgeReplace(ctx, message)
	case *application.PollBridge:
		a.pollBridge(ctx, message)
	case *projectionEvent:
		a.recordProjectionEvent(message.event)
	case *application.DropSession:
		a.dropSession(ctx, message)
	case *application.Subscribers:
		// Subscriber identities belong to GoAkt TopicActor and are intentionally
		// not mirrored or exposed by the domain actor.
		ctx.Response(&application.SubscriberList{})
	default:
		ctx.Unhandled()
	}
}

func (a *AgentActor) subscribe(ctx *actor.ReceiveContext, message *application.SubscribeAgent) {
	if message.AfterRevision != 0 {
		a.respondSubscription(ctx, message.Result, application.OperationResult{Reason: "nonzero after_revision replay is unsupported"})
		return
	}
	if !a.validHandle(message.SessionID, message.GenerationID, message.Principal, message.Handle, message.Fence, "observe") {
		a.respondSubscription(ctx, message.Result, application.OperationResult{Reason: "observe capability denied or stale handle"})
		return
	}
	key := generationKey(message.SessionID, message.GenerationID)
	if plan := a.projections[key]; plan != nil {
		if plan.closing {
			a.respondSubscription(ctx, message.Result, application.OperationResult{Reason: "projection subscription is closing"})
		} else if plan.subscribed {
			a.respondSubscription(ctx, message.Result, application.OperationResult{Completed: true, Revision: a.revision})
		} else if message.Result != nil {
			plan.requesters = append(plan.requesters, message.Result)
		}
		return
	}
	if ctx.ActorSystem().TopicActor() == nil {
		a.respondSubscription(ctx, message.Result, application.OperationResult{Reason: "projection subscription unavailable"})
		return
	}
	projection := &projectionActor{parent: ctx.Self(), topic: agentTopic(a.id), sessionID: message.SessionID, generationID: message.GenerationID, initialDelay: a.projectionSubscriptionDelay}
	var options []actor.SpawnOption
	if a.projectionMailbox != nil {
		options = append(options, actor.WithMailbox(a.projectionMailbox()))
	}
	child := ctx.Spawn(projectionName(message.SessionID, message.GenerationID), projection, options...)
	if child == nil {
		a.respondSubscription(ctx, message.Result, application.OperationResult{Reason: "projection subscription unavailable"})
		return
	}
	ctx.Watch(child)
	plan := &projectionLifecycle{pid: child, startSequence: a.bridgeSequence}
	if message.Result != nil {
		plan.requesters = append(plan.requesters, message.Result)
	}
	a.projections[key] = plan
}

func (*AgentActor) respondSubscription(ctx *actor.ReceiveContext, result chan<- application.OperationResult, response application.OperationResult) {
	if result != nil {
		deliverOperationResult(result, response)
	} else {
		ctx.Response(&response)
	}
}

func (a *AgentActor) unsubscribe(ctx *actor.ReceiveContext, message *application.UnsubscribeAgent) {
	if !a.validHandle(message.SessionID, message.GenerationID, message.Principal, message.Handle, message.Fence, "observe") {
		a.respondSubscription(ctx, message.Result, application.OperationResult{Reason: "observe capability denied or stale handle"})
		return
	}
	key := generationKey(message.SessionID, message.GenerationID)
	plan := a.projections[key]
	if plan == nil {
		a.respondSubscription(ctx, message.Result, application.OperationResult{Completed: true, Revision: a.revision})
		return
	}
	plan.closing = true
	if message.Result != nil {
		plan.closes = append(plan.closes, message.Result)
	}
	a.deliverProjectionClose(ctx, key, plan)
}

func (a *AgentActor) subscriptionAck(ctx *actor.ReceiveContext, message *projectionSubscribed) {
	key := generationKey(message.sessionID, message.generationID)
	plan := a.projections[key]
	if plan == nil {
		return
	}
	if plan.closing {
		a.deliverProjectionClose(ctx, key, plan)
		return
	}
	plan.subscribed = true
	for _, requester := range plan.requesters {
		deliverOperationResult(requester, application.OperationResult{Completed: true, Revision: a.revision})
	}
	plan.requesters = nil
	_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), plan.pid, &projectionSubscribedObserved{})
}

func (a *AgentActor) bridgeConnect(ctx *actor.ReceiveContext, message *application.BridgeConnect) {
	if message == nil || message.AgentID != a.id || message.RuntimeID != a.hostedPiRuntime.RuntimeID || message.Incarnation != a.hostedPiRuntime.Incarnation || message.PiSessionID == "" {
		respondBridge(ctx, message.Result, &application.BridgeResult{Reason: "hosted bridge binding rejected"})
		return
	}
	if a.bridgeSession != "" {
		if a.bridgeSession == message.SessionID && a.bridgeGeneration == message.GenerationID && a.bridgePrincipal == message.Principal && a.bridgePiSession == message.PiSessionID && a.validHandle(message.SessionID, message.GenerationID, message.Principal, a.bridgeHandle, a.bridgeFence, "hosted_bridge") {
			a.renewBridgeLease(ctx)
			respondBridge(ctx, message.Result, &application.BridgeResult{Accepted: true, Handle: a.bridgeHandle, Fence: a.bridgeFence})
			return
		}
		respondBridge(ctx, message.Result, &application.BridgeResult{Reason: "hosted bridge replacement requires an explicit fenced transition"})
		return
	}
	if message.Handle == "" {
		respondBridge(ctx, message.Result, &application.BridgeResult{NeedsAttach: true, Reason: "hosted bridge attachment required"})
		return
	}
	if !a.validHandle(message.SessionID, message.GenerationID, message.Principal, message.Handle, message.Fence, "hosted_bridge") {
		respondBridge(ctx, message.Result, &application.BridgeResult{Reason: "hosted bridge binding rejected"})
		return
	}
	if a.durablePending != nil || a.durableFailed != nil {
		respondBridge(ctx, message.Result, &application.BridgeResult{Reason: "durable persistence is busy"})
		return
	}
	old := a.durableState()
	a.bridgeSession, a.bridgeGeneration, a.bridgePrincipal, a.bridgePiSession = message.SessionID, message.GenerationID, message.Principal, message.PiSessionID
	a.bridgeHandle, a.bridgeFence = message.Handle, message.Fence
	a.renewBridgeLease(ctx)
	result := application.BridgeResult{Accepted: true, Handle: a.bridgeHandle, Fence: a.bridgeFence}
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: old, bridge: &result, bridgeCompletion: message.Result}) {
		return
	}
	respondBridge(ctx, message.Result, &result)
}

func (a *AgentActor) bridgeReplace(ctx *actor.ReceiveContext, message *application.BridgeReplace) {
	if message == nil || message.NewPiSessionID == "" || message.PreviousPiSessionID != a.bridgePiSession || message.SessionID != a.bridgeSession || message.GenerationID != a.bridgeGeneration || message.Principal != a.bridgePrincipal || message.RuntimeID != a.hostedPiRuntime.RuntimeID || message.Incarnation != a.hostedPiRuntime.Incarnation || !a.validHandle(message.SessionID, message.GenerationID, message.Principal, message.Handle, message.Fence, "hosted_bridge") {
		respondBridge(ctx, message.Result, &application.BridgeResult{Reason: "hosted bridge replacement fence rejected"})
		return
	}
	if a.durablePending != nil || a.durableFailed != nil {
		respondBridge(ctx, message.Result, &application.BridgeResult{Reason: "durable persistence is busy"})
		return
	}
	old := a.durableState()
	key := generationKey(message.SessionID, message.GenerationID)
	current := a.attachments[key]
	a.pruneRevokedMutationScope(message.SessionID, message.GenerationID, current.principal, current.fence)
	a.fence++
	current.handle, current.fence = message.NewHandle, a.fence
	a.attachments[key] = current
	a.bridgeHandle, a.bridgeFence, a.bridgePiSession = current.handle, current.fence, message.NewPiSessionID
	a.bridgeDeclaredReady = false
	a.bridgeLeaseToken++
	a.hostedPiRuntime.BridgeReady = false
	if a.runtimePID != nil {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), a.runtimePID, &application.HostedPiBridgeReadiness{Ready: false})
	}
	result := application.BridgeResult{Accepted: true, Handle: current.handle, Fence: current.fence}
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: old, bridge: &result, bridgeCompletion: message.Result}) {
		return
	}
	respondBridge(ctx, message.Result, &result)
}

func (a *AgentActor) bridgeLifecycle(ctx *actor.ReceiveContext, message *application.BridgeLifecycle) {
	if message == nil || (message.Event != application.BridgeLifecycleSessionStart && message.Event != application.BridgeLifecycleReady && message.Event != application.BridgeLifecycleSessionShutdown && message.Event != application.BridgeLifecycleAgentStart && message.Event != application.BridgeLifecycleAgentSettled) {
		respondBridge(ctx, message.Result, &application.BridgeResult{Reason: "unknown hosted bridge lifecycle event"})
		return
	}
	if message.AgentID != a.id || message.RuntimeID != a.hostedPiRuntime.RuntimeID || message.Incarnation != a.hostedPiRuntime.Incarnation || message.SessionID != a.bridgeSession || message.GenerationID != a.bridgeGeneration || message.Principal != a.bridgePrincipal || message.Handle != a.bridgeHandle || message.Fence != a.bridgeFence || !a.validHandle(message.SessionID, message.GenerationID, message.Principal, message.Handle, message.Fence, "hosted_bridge") {
		respondBridge(ctx, message.Result, &application.BridgeResult{Reason: "hosted bridge fence rejected"})
		return
	}
	if a.durablePending != nil || a.durableFailed != nil {
		respondBridge(ctx, message.Result, &application.BridgeResult{Reason: "durable persistence is busy"})
		return
	}
	old := a.durableState()
	ready := message.Event == application.BridgeLifecycleReady
	if ready {
		a.bridgeDeclaredReady = true
		a.renewBridgeLease(ctx)
	}
	if message.Event == application.BridgeLifecycleSessionShutdown {
		a.bridgeSession, a.bridgeGeneration, a.bridgePrincipal, a.bridgeHandle, a.bridgePiSession = "", "", "", "", ""
		a.bridgeFence = 0
		a.bridgeDeclaredReady = false
		a.bridgeLeaseToken++
	}
	if a.runtimePID != nil && (ready || message.Event == application.BridgeLifecycleSessionShutdown) {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), a.runtimePID, &application.HostedPiBridgeReadiness{Ready: ready})
	}
	if message.Event == application.BridgeLifecycleAgentStart || message.Event == application.BridgeLifecycleAgentSettled {
		operation := "pi_agent_start"
		if message.Event == application.BridgeLifecycleAgentSettled {
			operation = "pi_agent_settled"
		}
		a.bridgeSequence++
		a.bridgeEvents = append(a.bridgeEvents, application.BridgeEvent{Sequence: a.bridgeSequence, AgentID: a.id, Revision: a.revision, Operation: operation})
		if len(a.bridgeEvents) > maxBridgeItems {
			a.bridgeEvents = a.bridgeEvents[1:]
		}
	}
	result := application.BridgeResult{Accepted: true}
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: old, bridge: &result, bridgeCompletion: message.Result}) {
		return
	}
	respondBridge(ctx, message.Result, &result)
}

func (a *AgentActor) bridgeHeartbeat(ctx *actor.ReceiveContext, message *application.BridgeHeartbeat) {
	var result chan<- application.BridgeResult
	if message != nil {
		result = message.Result
	}
	if message == nil || message.AgentID != a.id || message.RuntimeID != a.hostedPiRuntime.RuntimeID || message.Incarnation != a.hostedPiRuntime.Incarnation || message.SessionID != a.bridgeSession || message.GenerationID != a.bridgeGeneration || message.Principal != a.bridgePrincipal || message.Handle != a.bridgeHandle || message.Fence != a.bridgeFence || !a.bridgeDeclaredReady || !a.validHandle(message.SessionID, message.GenerationID, message.Principal, message.Handle, message.Fence, "hosted_bridge") {
		respondBridge(ctx, result, &application.BridgeResult{Reason: "hosted bridge heartbeat fence rejected"})
		return
	}
	a.renewBridgeLease(ctx)
	respondBridge(ctx, message.Result, &application.BridgeResult{Accepted: true})
}

func (a *AgentActor) renewBridgeLease(ctx *actor.ReceiveContext) {
	a.bridgeLeaseToken++
	token := a.bridgeLeaseToken
	if a.bridgeDeclaredReady && !a.hostedPiRuntime.BridgeReady {
		a.hostedPiRuntime.BridgeReady = true
		if a.runtimePID != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), a.runtimePID, &application.HostedPiBridgeReadiness{Ready: true})
		}
	}
	_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &application.HostedPiBridgeLeaseExpired{Token: token}, ctx.Self(), bridgeLeaseDuration)
}

func (a *AgentActor) bridgeLeaseExpired(ctx *actor.ReceiveContext, message *application.HostedPiBridgeLeaseExpired) {
	if message == nil || message.Token != a.bridgeLeaseToken || !a.hostedPiRuntime.BridgeReady {
		return
	}
	a.hostedPiRuntime.BridgeReady = false
	if a.runtimePID != nil {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), a.runtimePID, &application.HostedPiBridgeReadiness{Ready: false})
	}
}

func (a *AgentActor) durableState() application.DurableAgentState {
	state := application.DurableAgentState{Revision: a.revision, CommandSequence: a.commandSequence, Fence: a.fence, BridgeFence: a.bridgeFence, BridgeSequence: a.bridgeSequence, BridgeLeaseToken: a.bridgeLeaseToken, BridgeReady: a.hostedPiRuntime.BridgeReady, BridgeDeclaredReady: a.bridgeDeclaredReady, BridgeSession: a.bridgeSession, BridgeGeneration: a.bridgeGeneration, BridgePrincipal: a.bridgePrincipal, BridgeHandle: a.bridgeHandle, BridgePiSession: a.bridgePiSession, BridgeDeliveries: append([]application.BridgeDelivery(nil), a.bridgeDeliveries...), DeliverySources: make(map[uint64]string, len(a.deliverySources)), TaskSources: make(map[uint64]application.DurableActorRef, len(a.durableTaskSources))}
	for sequence, key := range a.deliverySources {
		state.DeliverySources[sequence] = key
	}
	for _, key := range a.sourceOutboxOrder {
		if item, ok := a.sourceOutbox[key]; ok {
			state.SourceOutbox = append(state.SourceOutbox, item)
		}
	}
	for _, key := range a.sourceTaskHistoryOrder {
		if item, ok := a.sourceTaskHistory[key]; ok {
			state.SourceTaskHistory = append(state.SourceTaskHistory, item)
		}
	}
	for _, key := range a.taskCompletionOrder {
		if item, ok := a.taskCompletions[key]; ok {
			state.ReceivedTaskCompletions = append(state.ReceivedTaskCompletions, item)
		}
	}
	state.TaskCreditEpoch = a.taskCreditEpoch
	for source, reservation := range a.taskCreditReservations {
		state.TaskCreditReservations = append(state.TaskCreditReservations, application.DurableTaskCreditReservation{Credit: reservation.credit, Source: source})
	}
	for sequence, ref := range a.durableTaskSources {
		if _, retained := a.taskSources[sequence]; !retained {
			state.TaskSources[sequence] = ref
		}
	}
	for _, key := range a.completionTellOrder {
		if pending, retained := a.completionTellPending[key]; retained {
			state.CompletionTellPending = append(state.CompletionTellPending, pending)
		}
	}
	state.AckCursor = a.ackCursor
	for sequence, ack := range a.ackGaps {
		state.AckGapBuffer = append(state.AckGapBuffer, application.DurableBridgeAckRecord{Sequence: sequence, DedupeID: ack.DedupeID, Kind: ackDeliveryKind(ack.Kind), SourceScope: ack.SourceScope, CompletionKey: ack.CompletionKey, RuntimeID: ack.RuntimeID, Incarnation: ack.Incarnation, PiSessionID: ack.PiSessionID, Delivered: ack.Delivered, Reason: ack.Reason, Result: append([]byte(nil), ack.Result...)})
	}
	slices.SortFunc(state.AckGapBuffer, func(l, r application.DurableBridgeAckRecord) int {
		if l.Sequence < r.Sequence {
			return -1
		}
		return 1
	})
	for _, sequence := range a.committedAckOrder {
		if record, ok := a.committedAcks[sequence]; ok {
			state.CommittedAcks = append(state.CommittedAcks, record)
		}
	}
	for key := range a.revoked {
		state.Revoked = append(state.Revoked, key)
	}
	slices.Sort(state.Revoked)
	for key, item := range a.attachments {
		parts := splitGenerationKey(key)
		caps := make([]string, 0, len(item.capabilities))
		for cap := range item.capabilities {
			caps = append(caps, cap)
		}
		slices.Sort(caps)
		state.Attachments = append(state.Attachments, application.DurableAttachment{SessionID: parts[0], GenerationID: parts[1], Principal: item.principal, Handle: item.handle, Fence: item.fence, Capabilities: caps})
	}
	slices.SortFunc(state.Attachments, func(l, r application.DurableAttachment) int {
		return cmpString(l.SessionID+"\x00"+l.GenerationID, r.SessionID+"\x00"+r.GenerationID)
	})
	for key, scope := range a.mutationScopes {
		durable := application.DurableMutationScope{Key: key, Token: scope.token, SessionID: scope.sessionID, GenerationID: scope.generationID, Principal: scope.principal, Fence: scope.fence, Incarnation: scope.incarnation, HighWater: scope.highWater, Dedupe: make(map[string]application.DurableDedupeRecord, len(scope.dedupe))}
		for id, item := range scope.dedupe {
			durable.Dedupe[id] = application.DurableDedupeRecord{Sequence: item.sequence, MutationSequence: item.mutationSequence, ChainID: item.chainID}
		}
		for chain := range scope.chains {
			durable.Chains = append(durable.Chains, chain)
		}
		slices.Sort(durable.Chains)
		for _, sequence := range scope.order {
			item, ok := scope.results[sequence]
			if ok {
				durable.Results = append(durable.Results, application.DurableMutationResult{Sequence: sequence, Digest: item.digest, Pending: item.pending, Result: item.result, DedupeID: item.dedupeID, ChainID: item.chainID})
			}
		}
		state.MutationScopes = append(state.MutationScopes, durable)
	}
	slices.SortFunc(state.MutationScopes, func(l, r application.DurableMutationScope) int { return cmpString(l.Key, r.Key) })
	return state
}
func (a *AgentActor) restoreDurableState(state application.DurableAgentState) {
	a.revision, a.commandSequence, a.fence = state.Revision, state.CommandSequence, state.Fence
	a.bridgeFence, a.bridgeSequence, a.bridgeLeaseToken = state.BridgeFence, state.BridgeSequence, state.BridgeLeaseToken
	a.bridgeDeclaredReady = state.BridgeDeclaredReady
	a.hostedPiRuntime.BridgeReady = state.BridgeReady
	a.bridgeSession, a.bridgeGeneration, a.bridgePrincipal, a.bridgeHandle, a.bridgePiSession = state.BridgeSession, state.BridgeGeneration, state.BridgePrincipal, state.BridgeHandle, state.BridgePiSession
	a.bridgeDeliveries = append([]application.BridgeDelivery(nil), state.BridgeDeliveries...)
	a.deliverySources = make(map[uint64]string, len(state.DeliverySources))
	for sequence, key := range state.DeliverySources {
		a.deliverySources[sequence] = key
	}
	a.sourceOutbox = make(map[string]application.DurableActorTaskOutboxItem, len(state.SourceOutbox))
	a.sourceOutboxOrder = nil
	for _, item := range state.SourceOutbox {
		a.sourceOutbox[item.TaskID] = item
		a.sourceOutboxOrder = append(a.sourceOutboxOrder, item.TaskID)
	}
	a.sourceTaskHistory = make(map[string]application.ActorTaskCompleted, len(state.SourceTaskHistory))
	a.sourceTaskHistoryOrder = nil
	for _, item := range state.SourceTaskHistory {
		key := actorTaskID(a.id, item.OriginalRequestID, item.DedupeID, item.ChainID, item.SourceMutationSequence)
		a.sourceTaskHistory[key] = item
		a.sourceTaskHistoryOrder = append(a.sourceTaskHistoryOrder, key)
	}
	a.taskCompletions = make(map[string]application.ActorTaskCompleted, len(state.ReceivedTaskCompletions))
	a.taskCompletionOrder = nil
	for _, item := range state.ReceivedTaskCompletions {
		a.taskCompletions[item.CompletionKey] = item
		a.taskCompletionOrder = append(a.taskCompletionOrder, item.CompletionKey)
	}
	a.taskCreditEpoch = state.TaskCreditEpoch
	a.taskCreditReservations = make(map[string]taskCreditReservation, len(state.TaskCreditReservations))
	for _, item := range state.TaskCreditReservations {
		a.taskCreditReservations[item.Credit.CreditID] = taskCreditReservation{credit: item.Credit, source: item.Source}
	}
	a.durableTaskSources = make(map[uint64]application.DurableActorRef, len(state.TaskSources))
	for sequence, ref := range state.TaskSources {
		a.durableTaskSources[sequence] = ref
	}
	a.completionTellPending = make(map[string]application.DurablePendingCompletion, len(state.CompletionTellPending))
	a.completionTellOrder = nil
	for _, pending := range state.CompletionTellPending {
		a.completionTellPending[pending.CompletionKey] = pending
		a.completionTellOrder = append(a.completionTellOrder, pending.CompletionKey)
	}
	for len(a.completionTellOrder) > maxCompletionTells {
		oldest := a.completionTellOrder[0]
		a.completionTellOrder = a.completionTellOrder[1:]
		delete(a.completionTellPending, oldest)
	}
	a.resolvedRefs = make(map[string]*actor.PID)
	a.resolvingRefs = make(map[string]struct{})
	a.scopeTokens = make(map[string]string, len(state.MutationScopes))
	a.ackCursor = state.AckCursor
	a.ackGaps = make(map[uint64]application.BridgeDeliveryAck, len(state.AckGapBuffer))
	for _, record := range state.AckGapBuffer {
		a.ackGaps[record.Sequence] = application.BridgeDeliveryAck{Sequence: record.Sequence, DedupeID: record.DedupeID, Kind: application.BridgeDeliveryKindLabel(record.Kind), RuntimeID: record.RuntimeID, Incarnation: record.Incarnation, PiSessionID: record.PiSessionID, SourceScope: record.SourceScope, CompletionKey: record.CompletionKey, Delivered: record.Delivered, Reason: record.Reason, Result: append([]byte(nil), record.Result...)}
	}
	a.committedAcks = make(map[uint64]application.DurableBridgeAckRecord, len(state.CommittedAcks))
	a.committedAckOrder = nil
	for _, record := range state.CommittedAcks {
		a.committedAcks[record.Sequence] = record
		a.committedAckOrder = append(a.committedAckOrder, record.Sequence)
	}
	a.revoked = make(map[string]struct{}, len(state.Revoked))
	for _, key := range state.Revoked {
		a.revoked[key] = struct{}{}
	}
	a.attachments = make(map[string]attachment, len(state.Attachments))
	for _, item := range state.Attachments {
		caps := make(map[string]struct{}, len(item.Capabilities))
		for _, cap := range item.Capabilities {
			caps[cap] = struct{}{}
		}
		a.attachments[generationKey(item.SessionID, item.GenerationID)] = attachment{principal: item.Principal, handle: item.Handle, fence: item.Fence, capabilities: caps}
	}
	a.mutationScopes = make(map[string]*mutationScope, len(state.MutationScopes))
	for _, item := range state.MutationScopes {
		scope := &mutationScope{sessionID: item.SessionID, generationID: item.GenerationID, principal: item.Principal, fence: item.Fence, incarnation: item.Incarnation, token: item.Token, highWater: item.HighWater, results: make(map[uint64]mutationRecord), dedupe: make(map[string]bridgeDedupeRecord), chains: make(map[string]struct{}), asks: make(map[string]pendingBridgeAsk)}
		for _, result := range item.Results {
			scope.results[result.Sequence] = mutationRecord{digest: result.Digest, pending: result.Pending, result: result.Result, dedupeID: result.DedupeID, chainID: result.ChainID}
			scope.order = append(scope.order, result.Sequence)
			if !result.Pending {
				scope.completed++
			}
		}
		for id, dedupe := range item.Dedupe {
			scope.dedupe[id] = bridgeDedupeRecord{sequence: dedupe.Sequence, mutationSequence: dedupe.MutationSequence, chainID: dedupe.ChainID}
		}
		for _, chain := range item.Chains {
			scope.chains[chain] = struct{}{}
		}
		a.mutationScopes[item.Key] = scope
		if item.Token != "" {
			// Rebuild the server-side token-to-internal-key mapping: the token
			// is the only scope identity that ever leaves owner state.
			a.scopeTokens[item.Token] = item.Key
		}
	}
}
func (a *AgentActor) snapshotPendingAsks() map[string]map[string]pendingBridgeAsk {
	result := make(map[string]map[string]pendingBridgeAsk)
	for key, scope := range a.mutationScopes {
		if len(scope.asks) == 0 {
			continue
		}
		items := make(map[string]pendingBridgeAsk, len(scope.asks))
		for dedupeID, ask := range scope.asks {
			items[dedupeID] = ask
		}
		result[key] = items
	}
	return result
}

func (a *AgentActor) restorePendingAsks(snapshot map[string]map[string]pendingBridgeAsk) {
	for key, items := range snapshot {
		if scope := a.mutationScopes[key]; scope != nil {
			for dedupeID, ask := range items {
				scope.asks[dedupeID] = ask
			}
		}
	}
}

// cloneTaskSources snapshots the live delivery-to-source PID map so a
// persistence rollback can restore entries the rolled-back mutation retired.
func (a *AgentActor) cloneTaskSources() map[uint64]*actor.PID {
	if len(a.taskSources) == 0 {
		return nil
	}
	snapshot := make(map[uint64]*actor.PID, len(a.taskSources))
	for sequence, pid := range a.taskSources {
		snapshot[sequence] = pid
	}
	return snapshot
}

func (a *AgentActor) beginDurablePersist(ctx *actor.ReceiveContext, receipt *pendingDurableReceipt) bool {
	if a.durableRecord == nil || a.persistencePID == nil {
		return false
	}
	// An in-flight receipt must never be overwritten: a second concurrent
	// persistence attempt is rejected fail-closed after rolling back its own
	// optimistic mutation.
	if a.durablePending != nil {
		a.restoreDurableState(receipt.old)
		a.completeDurableReceipt(ctx, receipt, fmt.Errorf("durable persistence is busy"))
		return true
	}
	if a.durableFailed != nil {
		a.restoreDurableState(receipt.old)
		a.completeDurableReceipt(ctx, receipt, a.durableFailed)
		return true
	}
	a.durablePending = receipt
	a.submitDurableState(ctx, receipt, a.durableState())
	return true
}

func (a *AgentActor) submitDurableState(ctx *actor.ReceiveContext, receipt *pendingDurableReceipt, state application.DurableAgentState) {
	a.durableCorrelation++
	receipt.correlation = a.durableCorrelation
	record := *a.durableRecord
	// Terminal records must round-trip their own reconcile: the registry
	// validator accepts only the pristine inactive binding for terminal
	// agents, so live display metadata never enters the durable binding.
	if a.authorityBinding.Kind != application.AuthorityBindingHostedOwned {
		record.Binding = application.InactiveHostedPiRuntimeBinding()
	} else {
		record.Binding = a.hostedPiRuntime
	}
	record.AgentState = state
	if err := ctx.Self().Tell(context.WithoutCancel(ctx.Context()), a.persistencePID, &application.PersistDurableHostedState{Record: record, Owner: ctx.Self(), Correlation: receipt.correlation}); err != nil {
		a.durablePersisted(ctx, &application.DurableHostedStatePersisted{Correlation: receipt.correlation, Err: err})
	}
}

func (a *AgentActor) durablePersisted(ctx *actor.ReceiveContext, message *application.DurableHostedStatePersisted) {
	pending := a.durablePending
	if pending == nil || message.Correlation != pending.correlation {
		// A persistence reply that does not match the single in-flight receipt
		// means the persistence conversation is no longer provable: fail closed
		// instead of silently dropping the mismatched correlation.
		err := fmt.Errorf("unexpected durable persistence reply correlation %d", message.Correlation)
		if pending != nil {
			err = fmt.Errorf("durable persistence correlation %d does not match in-flight receipt %d", message.Correlation, pending.correlation)
		}
		a.durableFailed = errors.Join(a.durableFailed, err)
		a.hostedPiRuntime.State = application.HostedPiRuntimeDegraded
		a.hostedPiRuntime.BridgeReady = false
		if a.persistenceSupervisor != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), a.persistenceSupervisor, &application.QuarantineDurableHostedState{AgentID: a.id, Reason: "durable persistence correlation mismatch", Err: err})
		}
		if pending != nil {
			a.durablePending = nil
			a.completeDurableReceipt(ctx, pending, a.durableFailed)
		}
		return
	}
	if message.Err != nil && !pending.rollingBack {
		asks := a.snapshotPendingAsks()
		readyAfterEffect := a.hostedPiRuntime.BridgeReady
		a.restoreDurableState(pending.old)
		// Live source PIDs never enter the durable state: restore the ones the
		// rolled-back mutation retired from the receipt snapshot.
		for sequence, pid := range pending.liveTaskSources {
			a.taskSources[sequence] = pid
		}
		if !readyAfterEffect {
			a.hostedPiRuntime.BridgeReady = false
		}
		if a.runtimePID == nil {
			a.hostedPiRuntime.State = application.HostedPiRuntimeDegraded
			a.hostedPiRuntime.BridgeReady = false
		}
		// An incarnation-retirement transition swaps the runtime binding as part
		// of its batch: roll the binding back with the agent state so the
		// re-driven state change re-runs the retirement from its exact start.
		if pending.runtimeRollbackBinding != nil {
			restored := *pending.runtimeRollbackBinding
			restored.BridgeReady = a.hostedPiRuntime.BridgeReady
			a.hostedPiRuntime = restored
			if a.durableRecord != nil {
				a.durableRecord.Binding = restored
				a.durableRecord.LaunchSpec.Incarnation = restored.Incarnation
			}
		}
		a.restorePendingAsks(asks)
		if pending.removeAskOnFailure {
			if scope := a.mutationScopes[pending.askScope]; scope != nil {
				delete(scope.asks, pending.askDedupe)
			}
		}
		if pending.askCompletion != nil {
			if scope := a.mutationScopes[pending.askScope]; scope != nil {
				scope.asks[pending.askDedupe] = pendingBridgeAsk{completion: pending.askCompletion}
			}
		}
		// Ack-burst commits removed their pending asks before persisting; the
		// generic ask snapshot above no longer contains them, so re-register each
		// effect's ask before the rollback submission.
		if pending.ackBurst != nil {
			for index := range pending.ackBurst.commits {
				effect := &pending.ackBurst.commits[index]
				if effect.askCompletion != nil {
					if scope := a.mutationScopes[effect.scopeKey]; scope != nil {
						scope.asks[effect.dedupeID] = pendingBridgeAsk{completion: effect.askCompletion}
					}
				}
			}
		}
		pending.persistErr = message.Err
		pending.rollingBack = true
		rollbackState := pending.old
		rollbackState.BridgeReady = a.hostedPiRuntime.BridgeReady
		rollbackState.BridgeDeclaredReady = a.bridgeDeclaredReady
		rollbackState.BridgeLeaseToken = a.bridgeLeaseToken
		a.submitDurableState(ctx, pending, rollbackState)
		return
	}

	a.durablePending = nil
	resultErr := message.Err
	if pending.rollingBack {
		if message.Err == nil {
			resultErr = pending.persistErr
			if a.durableRecord != nil {
				a.durableRecord.Binding = a.hostedPiRuntime
				a.durableRecord.AgentState = a.durableState()
			}
		} else {
			resultErr = errors.Join(pending.persistErr, fmt.Errorf("durable rollback failed: %w", message.Err))
			a.durableFailed = resultErr
			a.hostedPiRuntime.State = application.HostedPiRuntimeDegraded
			a.hostedPiRuntime.BridgeReady = false
		}
	} else if a.durableRecord != nil {
		a.durableRecord.Binding = a.hostedPiRuntime
		a.durableRecord.AgentState = a.durableState()
	}
	if resultErr != nil && a.persistenceSupervisor != nil {
		reason := "durable persistence failed"
		if a.durableFailed != nil {
			reason = "durable persistence rollback is indeterminate"
		}
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), a.persistenceSupervisor, &application.QuarantineDurableHostedState{AgentID: a.id, Reason: reason, Err: resultErr})
	}
	a.completeDurableReceipt(ctx, pending, resultErr)
	if resultErr != nil && pending.retryTimeout && a.durableFailed == nil {
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &application.BridgeIntentTimeout{ScopeKey: pending.askScope, DedupeID: pending.askDedupe}, ctx.Self(), 10*time.Millisecond)
	}
	if resultErr != nil && pending.runtimeStateForward != nil && a.durableFailed == nil {
		retry := *pending.runtimeStateForward
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &retry, ctx.Self(), 10*time.Millisecond)
	}
	if resultErr == nil && pending.timeoutScope != "" {
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &application.BridgeIntentTimeout{ScopeKey: pending.timeoutScope, DedupeID: pending.timeoutDedupe}, ctx.Self(), max(pending.timeout, time.Millisecond))
	}
}

func (a *AgentActor) completeDurableReceipt(ctx *actor.ReceiveContext, pending *pendingDurableReceipt, err error) {
	if err != nil {
		if a.durableFailed != nil && pending.askCompletion != nil {
			deliverBridgeIntentResult(pending.askCompletion, application.BridgeIntentResult{Reason: "durable state rollback is indeterminate"})
		}
		if pending.attach != nil {
			pending.attach = &application.AttachResult{Reason: "durable attachment persistence failed"}
		}
		if pending.bridge != nil {
			pending.bridge = &application.BridgeResult{Reason: "durable bridge persistence failed"}
		}
		if pending.intent != nil {
			pending.intent = &application.BridgeIntentResult{Reason: "durable mutation persistence failed"}
		}
		if pending.ackBurst != nil {
			// Fail the whole contiguous burst closed: cursor, replay window, and
			// buffered acknowledgements all roll back together.
			pending.ackBurst.result = application.BridgeDeliveryAckResult{Reason: "durable acknowledgement persistence failed", Cursor: a.ackCursor}
		}
	} else {
		if pending.askCompletion != nil && pending.askResult != nil {
			deliverBridgeIntentResult(pending.askCompletion, *pending.askResult)
		}
		if pending.ackBurst != nil {
			a.deliverAckBurstEffects(ctx, pending.ackBurst)
		}
		if pending.runtimeStateForward != nil {
			// The retirement batch committed: release the registry projection
			// forward and the bounded completion redrive. The burst effects were
			// already delivered above, so they must not fire twice.
			a.completeRuntimeStateEffects(ctx, pending.runtimeStateForward, nil)
		}
		// A receipt that retained a completion tell during its mutation must
		// keep the bounded redrive loop alive on the durable path too.
		a.scheduleCompletionRetry(ctx)
		if pending.sender != nil && pending.taskCreditGrant != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), pending.sender, pending.taskCreditGrant)
		}
		if pending.sender != nil && pending.taskAccepted != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), pending.sender, pending.taskAccepted)
		}
		if pending.sourceCreditTarget != nil && pending.sourceCreditItem != nil {
			a.requestOutboxCredit(ctx, pending.sourceCreditTarget, *pending.sourceCreditItem)
		}
		if pending.taskCompletionPublish != nil {
			a.publishTaskCompletion(ctx, pending.taskCompletionPublish)
		}
		if pending.targetTaskCommitted != nil {
			a.publishTargetTaskCommitted(ctx, pending.targetTaskCommitted)
		}
	}
	if pending.drop != nil {
		if err == nil {
			a.continueDrop(ctx, *pending.drop)
		}
		return
	}
	if pending.attachCompletion != nil && pending.attach != nil {
		deliverAttachResult(pending.attachCompletion, *pending.attach)
	} else if pending.bridgeCompletion != nil && pending.bridge != nil {
		deliverBridgeResult(pending.bridgeCompletion, *pending.bridge)
	} else if pending.intentCompletion != nil && pending.intent != nil {
		deliverBridgeIntentResult(pending.intentCompletion, *pending.intent)
	} else if pending.ackBurst != nil {
		if pending.ackBurst.response != nil {
			deliverBridgeAckResult(pending.ackBurst.response, pending.ackBurst.result)
		}
	} else if pending.operation != nil {
		result := application.OperationResult{Completed: err == nil}
		if pending.operationResult != nil {
			result = *pending.operationResult
			result.Completed = err == nil
		}
		if err != nil {
			result.Reason = "durable state persistence failed: " + err.Error()
		}
		deliverOperationResult(pending.operation, result)
	} else if pending.taskCreditGrant != nil || pending.taskAccepted != nil {
		return
	} else if pending.sender != nil {
		if pending.attach != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), pending.sender, pending.attach)
		} else if pending.intent != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), pending.sender, pending.intent)
		} else {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), pending.sender, &application.OperationResult{Completed: err == nil, Reason: func() string {
				if err != nil {
					return "durable state persistence failed"
				}
				return ""
			}()})
		}
	}
}
func (a *AgentActor) restoreDurableTimers(ctx *actor.ReceiveContext) {
	for _, delivery := range a.bridgeDeliveries {
		key := a.deliverySources[delivery.Sequence]
		scope := a.mutationScopes[key]
		if scope == nil {
			continue
		}
		record, ok := scope.dedupe[delivery.DedupeID]
		if !ok || record.sequence != delivery.Sequence {
			continue
		}
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &application.BridgeIntentTimeout{ScopeKey: key, DedupeID: delivery.DedupeID}, ctx.Self(), max(time.Until(delivery.Deadline), time.Millisecond))
	}
	if len(a.sourceOutbox) != 0 || len(a.completionTellPending) != 0 {
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &retrySourceOutbox{}, ctx.Self(), outboxBaseRetryDelay)
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &retryCompletionTells{}, ctx.Self(), outboxBaseRetryDelay)
	}
}

func (a *AgentActor) durableBarrier(ctx *actor.ReceiveContext) {
	message := ctx.Message().(*application.DurableBarrier)
	if a.durablePending != nil || a.durableFailed != nil {
		result := application.OperationResult{Reason: "durable persistence is busy"}
		if message.Result != nil {
			deliverOperationResult(message.Result, result)
		} else {
			ctx.Response(&result)
		}
		return
	}
	old := a.durableState()
	if message.Result != nil {
		if !a.beginDurablePersist(ctx, &pendingDurableReceipt{operation: message.Result, old: old}) {
			deliverOperationResult(message.Result, application.OperationResult{Completed: true})
		}
		return
	}
	if !a.beginDurablePersist(ctx, &pendingDurableReceipt{sender: ctx.Sender(), old: old}) {
		ctx.Response(&application.OperationResult{Completed: true})
	}
}

func (a *AgentActor) sendActorTask(ctx *actor.ReceiveContext, message *application.SendActorTask) {
	if message == nil {
		respondBridgeIntent(ctx, nil, &application.BridgeIntentResult{Reason: "invalid, expired, or stale actor task"})
		return
	}
	if message.TargetPID == nil || message.RequestID == "" || message.DedupeID == "" || message.ChainID == "" || message.SourceMutationSequence == 0 || message.HopLimit == 0 || time.Now().After(message.Deadline) || len(message.Payload) == 0 || len(message.Payload) > maxBridgePayloadBytes {
		respondBridgeIntent(ctx, message.Receipt, &application.BridgeIntentResult{Reason: "invalid, expired, or stale actor task"})
		return
	}
	if a.durablePending != nil || a.durableFailed != nil {
		respondBridgeIntent(ctx, message.Receipt, &application.BridgeIntentResult{Reason: "durable persistence is busy"})
		return
	}
	taskID := actorTaskID(a.id, message.RequestID, message.DedupeID, message.ChainID, message.SourceMutationSequence)
	if completion, ok := a.sourceTaskHistory[taskID]; ok {
		result := completion.Terminal
		respondBridgeIntent(ctx, message.Receipt, &result)
		return
	}
	sequenceSuffix := fmt.Sprintf(":%d", message.SourceMutationSequence)
	for key := range a.sourceTaskHistory {
		if strings.HasPrefix(key, a.id+":") && strings.HasSuffix(key, sequenceSuffix) {
			respondBridgeIntent(ctx, message.Receipt, &application.BridgeIntentResult{Reason: "source mutation sequence collision"})
			return
		}
	}
	for key := range a.sourceOutbox {
		if key != taskID && strings.HasPrefix(key, a.id+":") && strings.HasSuffix(key, sequenceSuffix) {
			respondBridgeIntent(ctx, message.Receipt, &application.BridgeIntentResult{Reason: "source mutation sequence collision"})
			return
		}
	}
	for _, completion := range a.taskCompletions {
		if completion.OriginalRequestID == message.RequestID && completion.DedupeID == message.DedupeID && completion.ChainID == message.ChainID && completion.SourceMutationSequence == message.SourceMutationSequence {
			result := completion.Terminal
			respondBridgeIntent(ctx, message.Receipt, &result)
			return
		}
	}
	if message.TargetPeer.StableID == a.id {
		if scope := a.mutationScopes[sourceMutationScopeKey("actor", "actor", a.id, 0, a.hostedPiRuntime.Incarnation)]; scope != nil {
			if record, ok := scope.results[message.SourceMutationSequence]; ok && !record.pending && record.dedupeID == message.DedupeID && record.chainID == message.ChainID {
				result := record.result
				respondBridgeIntent(ctx, message.Receipt, &result)
				return
			}
		}
	}
	if len(a.sourceOutbox) >= maxSourceOutboxItems {
		respondBridgeIntent(ctx, message.Receipt, &application.BridgeIntentResult{Reason: "source actor task outbox is full"})
		return
	}
	if _, exists := a.sourceOutbox[taskID]; exists {
		respondBridgeIntent(ctx, message.Receipt, &application.BridgeIntentResult{Accepted: true, AwaitingAck: true, Reason: "stored_pending_credit"})
		return
	}
	old := a.durableState()
	item := application.DurableActorTaskOutboxItem{TaskID: taskID, Target: message.TargetPeer, RequestID: message.RequestID, DedupeID: message.DedupeID, ChainID: message.ChainID, RequiredCapability: message.RequiredCapability, SourceMutationSequence: message.SourceMutationSequence, Deadline: message.Deadline, HopLimit: message.HopLimit, Mode: message.Mode, Payload: append([]byte(nil), message.Payload...), PayloadDigest: sha256.Sum256(message.Payload), State: "pending_credit"}
	item.TargetRef = actorRefFromPID(message.TargetPeer.StableID, message.TargetPID)
	a.sourceOutbox[taskID] = item
	a.sourceOutboxOrder = append(a.sourceOutboxOrder, taskID)
	persisting := a.beginDurablePersist(ctx, &pendingDurableReceipt{old: old, intent: &application.BridgeIntentResult{Accepted: true, AwaitingAck: true, Reason: "stored_pending_credit"}, intentCompletion: message.Receipt, sourceCreditTarget: message.TargetPID, sourceCreditItem: &item})
	if !persisting {
		respondBridgeIntent(ctx, message.Receipt, &application.BridgeIntentResult{Accepted: true, AwaitingAck: true, Reason: "stored_pending_credit"})
		a.requestOutboxCredit(ctx, message.TargetPID, item)
	}
}

func (a *AgentActor) requestTaskCredit(ctx *actor.ReceiveContext, message *application.RequestTaskCredit) {
	sender := ctx.Sender()
	if message == nil || sender == nil || isNoSender(ctx, sender) || message.TaskID == "" || time.Now().After(message.Deadline) {
		if sender != nil && !isNoSender(ctx, sender) && message != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), sender, &application.TaskBackpressured{TaskID: message.TaskID, Reason: "invalid credit request", RetryAfter: taskRetryDelay})
		}
		return
	}
	if a.durablePending != nil || a.durableFailed != nil {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), sender, &application.TaskBackpressured{TaskID: message.TaskID, TargetEpoch: a.taskCreditEpoch, Reason: "durable persistence is busy", RetryAfter: taskRetryDelay})
		return
	}
	a.expireTaskCredits()
	available := maxTargetTaskQueueItems - len(a.bridgeDeliveries) - len(a.taskCreditReservations)
	if available <= 0 {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), sender, &application.TaskBackpressured{TaskID: message.TaskID, TargetEpoch: a.taskCreditEpoch, Reason: "target task capacity is full", RetryAfter: taskRetryDelay})
		return
	}
	old := a.durableState()
	a.taskCreditEpoch++
	credit := application.TaskCredit{TaskID: message.TaskID, CreditID: taskCreditID(a.id, message.TaskID, a.taskCreditEpoch), TargetEpoch: a.taskCreditEpoch, ExpiresAt: minTime(time.Now().Add(taskCreditLease), message.Deadline), PayloadDigest: message.PayloadDigest}
	a.taskCreditReservations[credit.CreditID] = taskCreditReservation{credit: credit, source: sender.Name(), replyTo: sender}
	granted := &application.TaskCreditGranted{Credit: credit}
	if !a.beginDurablePersist(ctx, &pendingDurableReceipt{sender: sender, old: old, taskCreditGrant: granted}) {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), sender, granted)
	}
	_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &application.TaskBackpressured{TaskID: credit.TaskID, TargetEpoch: credit.TargetEpoch, Reason: "credit expired"}, ctx.Self(), max(time.Until(credit.ExpiresAt), time.Millisecond))
}

func (a *AgentActor) taskCreditGranted(ctx *actor.ReceiveContext, message *application.TaskCreditGranted) {
	if message == nil {
		return
	}
	item, ok := a.sourceOutbox[message.Credit.TaskID]
	if !ok || item.PayloadDigest != message.Credit.PayloadDigest || time.Now().After(message.Credit.ExpiresAt) || time.Now().After(item.Deadline) {
		return
	}
	// Only the exact target agent this outbox entry requested credit from may
	// hand the credit back; any other origin is fail-closed before effects.
	sender := ctx.Sender()
	if sender == nil || isNoSender(ctx, sender) || !actorRefMatchesSender(&item.TargetRef, sender) {
		return
	}
	item.Credit = message.Credit
	item.State = "sent"
	a.sourceOutbox[item.TaskID] = item
	task := &application.ActorTask{Credit: message.Credit, SourcePeer: a.communicationPeer(), TargetPeer: item.Target, RequestID: item.RequestID, DedupeID: item.DedupeID, ChainID: item.ChainID, RequiredCapability: item.RequiredCapability, SourceMutationSequence: item.SourceMutationSequence, Deadline: item.Deadline, HopLimit: item.HopLimit, Mode: item.Mode, Payload: append([]byte(nil), item.Payload...)}
	if sender := ctx.Sender(); sender != nil {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), sender, task)
	}
}

func (a *AgentActor) taskBackpressured(ctx *actor.ReceiveContext, message *application.TaskBackpressured) {
	if message == nil {
		return
	}
	if item, ok := a.sourceOutbox[message.TaskID]; ok && time.Now().Before(item.Deadline) {
		item.State = "pending_credit"
		a.sourceOutbox[message.TaskID] = item
	}
}

func (a *AgentActor) actorTask(ctx *actor.ReceiveContext, message *application.ActorTask) {
	replyTo := ctx.Sender()
	if message == nil || replyTo == nil || isNoSender(ctx, replyTo) {
		return
	}
	reservation, ok := a.taskCreditReservations[message.Credit.CreditID]
	if !ok || reservation.credit.TaskID != message.Credit.TaskID || reservation.credit.TargetEpoch != message.Credit.TargetEpoch || reservation.credit.PayloadDigest != sha256.Sum256(message.Payload) || time.Now().After(reservation.credit.ExpiresAt) || message.Credit.PayloadDigest != reservation.credit.PayloadDigest {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), replyTo, &application.ActorTaskAccepted{TaskID: message.Credit.TaskID, CreditID: message.Credit.CreditID, TargetAgentID: a.id, Reason: "invalid, expired, duplicate, or stale task credit"})
		return
	}
	// The task may only spend a credit that this actor reserved for the exact
	// requesting sender; forged or rebound origins are rejected fail-closed.
	if reservation.replyTo == nil || !replyTo.Equals(reservation.replyTo) {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), replyTo, &application.ActorTaskAccepted{TaskID: message.Credit.TaskID, CreditID: message.Credit.CreditID, TargetAgentID: a.id, Reason: "task credit sender identity rejected"})
		return
	}
	if a.durablePending != nil || a.durableFailed != nil {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), replyTo, &application.ActorTaskAccepted{TaskID: message.Credit.TaskID, CreditID: message.Credit.CreditID, TargetAgentID: a.id, Reason: "durable persistence is busy"})
		return
	}
	old := a.durableState()
	delete(a.taskCreditReservations, message.Credit.CreditID)
	intent := &application.BridgeIntent{SessionID: "actor", GenerationID: "actor", Principal: message.SourcePeer.StableID, Handle: "actor", SourceAgentID: message.SourcePeer.StableID, TargetAgentID: a.id, RequestID: message.RequestID, RequiredCapability: message.RequiredCapability, DedupeID: message.DedupeID, ChainID: message.ChainID, SourceMutationSequence: message.SourceMutationSequence, Deadline: message.Deadline, HopLimit: message.HopLimit, Mode: message.Mode, Payload: append([]byte(nil), message.Payload...)}
	if !a.acceptActorTaskWithCredit(ctx, intent, replyTo, message.SourcePeer, old) {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), replyTo, &application.ActorTaskAccepted{TaskID: message.Credit.TaskID, CreditID: message.Credit.CreditID, TargetAgentID: a.id, Reason: "actor task rejected"})
	}
}

func (a *AgentActor) actorTaskAccepted(ctx *actor.ReceiveContext, message *application.ActorTaskAccepted) {
	if message == nil || !message.Accepted {
		return
	}
	item, ok := a.sourceOutbox[message.TaskID]
	if !ok {
		return
	}
	// A forged acceptance must not retire the outbox entry or publish a
	// commit: only the exact reserved target agent may acknowledge it.
	sender := ctx.Sender()
	if sender == nil || isNoSender(ctx, sender) || !actorRefMatchesSender(&item.TargetRef, sender) || message.TargetAgentID != item.TargetRef.AgentID || message.TargetAgentID != item.Target.StableID {
		return
	}
	if a.durablePending != nil || a.durableFailed != nil {
		return
	}
	old := a.durableState()
	delete(a.sourceOutbox, message.TaskID)
	a.sourceOutboxOrder = slices.DeleteFunc(a.sourceOutboxOrder, func(id string) bool { return id == message.TaskID })
	committed := &application.TargetTaskCommitted{TaskID: message.TaskID, TargetAgentID: message.TargetAgentID}
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: old, targetTaskCommitted: committed}) {
		return
	}
	a.publishTargetTaskCommitted(ctx, committed)
}

func (a *AgentActor) retrySourceOutbox(ctx *actor.ReceiveContext) {
	if a.durablePending != nil || a.durableFailed != nil {
		a.scheduleOutboxRetry(ctx)
		return
	}
	now := time.Now()
	old := a.durableState()
	changed := false
	for _, taskID := range append([]string(nil), a.sourceOutboxOrder...) {
		item, exists := a.sourceOutbox[taskID]
		if !exists {
			continue
		}
		if now.After(item.Deadline) {
			// Deadline failure for lost credit/task/acceptance: retain a
			// terminal failure result, publish it to the source mailbox, and
			// retire the outbox entry.
			failed := application.ActorTaskCompleted{CompletionKey: taskID, OriginalRequestID: item.RequestID, DedupeID: item.DedupeID, ChainID: item.ChainID, SourceMutationSequence: item.SourceMutationSequence, Terminal: application.BridgeIntentResult{Reason: "actor task deadline expired before delivery"}, Source: a.communicationPeer(), Target: item.Target, Kind: application.BridgeDeliveryNotification}
			a.retainSourceCompletion(taskID, failed)
			delete(a.sourceOutbox, taskID)
			a.sourceOutboxOrder = slices.DeleteFunc(a.sourceOutboxOrder, func(id string) bool { return id == taskID })
			changed = true
			continue
		}
		if now.Before(item.NextAttempt) {
			continue
		}
		// Attempt bookkeeping stays in memory: redrive sends are idempotent by
		// task identity and must not open durable persistence windows that
		// would reject concurrent mutations as busy.
		item.Attempts++
		item.NextAttempt = now.Add(outboxRetryDelay(item.Attempts))
		a.sourceOutbox[taskID] = item
		// Remote resolution runs as an async continuation: this receive path
		// only enqueues the lookup and retries on the next bounded tick once the
		// resolved PID is cached.
		target := a.cachedActorRef(item.TargetRef.Address)
		if target == nil {
			a.resolveActorRefAsync(ctx, item.TargetRef)
			continue
		}
		if item.State == "sent" && item.Credit.CreditID != "" && now.Before(item.Credit.ExpiresAt) {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), target, &application.ActorTask{Credit: item.Credit, SourcePeer: a.communicationPeer(), TargetPeer: item.Target, RequestID: item.RequestID, DedupeID: item.DedupeID, ChainID: item.ChainID, RequiredCapability: item.RequiredCapability, SourceMutationSequence: item.SourceMutationSequence, Deadline: item.Deadline, HopLimit: item.HopLimit, Mode: item.Mode, Payload: append([]byte(nil), item.Payload...)})
		} else {
			a.requestOutboxCredit(ctx, target, item)
		}
	}
	// Every pending item keeps one bounded backoff tick scheduled until it is
	// accepted or terminal: a pure redrive send (no durable state change) must
	// not starve the loop of its next retry.
	a.scheduleOutboxRetry(ctx)
	if !changed {
		return
	}
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: old}) {
		return
	}
}

func (a *AgentActor) scheduleOutboxRetry(ctx *actor.ReceiveContext) {
	if len(a.sourceOutbox) == 0 {
		return
	}
	_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &retrySourceOutbox{}, ctx.Self(), outboxBaseRetryDelay)
}

func outboxRetryDelay(attempts int) time.Duration {
	delay := outboxBaseRetryDelay
	for range min(attempts, 6) {
		delay *= 2
		if delay > outboxMaxRetryDelay {
			return outboxMaxRetryDelay
		}
	}
	return delay
}

// deferCompletionTell durably retains a terminal completion whose cross-node
// Tell failed, with bounded redrive attempts.
func (a *AgentActor) deferCompletionTell(ctx *actor.ReceiveContext, effect *ackCommitEffect, err error) {
	if effect.taskCompletion == nil || effect.taskCompletion.CompletionKey == "" {
		return
	}
	if a.durablePending != nil || a.durableFailed != nil {
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &retryCompletionTells{}, ctx.Self(), outboxBaseRetryDelay)
		return
	}
	if _, exists := a.completionTellPending[effect.taskCompletion.CompletionKey]; exists {
		return
	}
	source := actorRefFromPID("", effect.taskReplyTo)
	old := a.durableState()
	a.completionTellPending[effect.taskCompletion.CompletionKey] = application.DurablePendingCompletion{CompletionKey: effect.taskCompletion.CompletionKey, Source: source, Completed: *effect.taskCompletion}
	a.completionTellOrder = append(a.completionTellOrder, effect.taskCompletion.CompletionKey)
	for len(a.completionTellOrder) > maxCompletionTells {
		oldest := a.completionTellOrder[0]
		a.completionTellOrder = a.completionTellOrder[1:]
		delete(a.completionTellPending, oldest)
	}
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: old}) {
		return
	}
	_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &retryCompletionTells{}, ctx.Self(), outboxBaseRetryDelay)
	_ = err
}

func (a *AgentActor) retryCompletionTells(ctx *actor.ReceiveContext) {
	if a.durablePending != nil || a.durableFailed != nil {
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &retryCompletionTells{}, ctx.Self(), outboxBaseRetryDelay)
		return
	}
	old := a.durableState()
	changed := false
	for _, key := range append([]string(nil), a.completionTellOrder...) {
		pending, exists := a.completionTellPending[key]
		if !exists {
			continue
		}
		// Remote resolution runs as an async continuation: this receive path
		// only enqueues the lookup; the resolved PID (or its bounded failure)
		// arrives back as a message and the next tick delivers.
		target := a.cachedActorRef(pending.Source.Address)
		if target == nil {
			a.resolveActorRefAsync(ctx, pending.Source)
			continue
		}
		if err := ctx.Self().Tell(context.WithoutCancel(ctx.Context()), target, &pending.Completed); err != nil {
			pending.Attempts++
			a.completionTellPending[key] = pending
			changed = true
		} else {
			delete(a.completionTellPending, key)
			a.completionTellOrder = slices.DeleteFunc(a.completionTellOrder, func(id string) bool { return id == key })
			changed = true
		}
		if pending.Attempts >= maxCompletionAttempts {
			delete(a.completionTellPending, key)
			a.completionTellOrder = slices.DeleteFunc(a.completionTellOrder, func(id string) bool { return id == key })
			changed = true
		}
	}
	// Keep the bounded retry loop alive across resolution windows: pending
	// completions always schedule their next tick until delivered or terminal.
	if len(a.completionTellPending) != 0 {
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &retryCompletionTells{}, ctx.Self(), outboxRetryDelay(2))
	}
	if !changed {
		return
	}
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: old}) {
		return
	}
}

func actorRefFromPID(agentID string, pid *actor.PID) application.DurableActorRef {
	ref := application.DurableActorRef{AgentID: agentID}
	if pid == nil {
		return ref
	}
	if path := pid.Path(); path != nil {
		ref.Host, ref.Port, ref.Name = path.Host(), path.Port(), path.Name()
	}
	ref.Address = pid.ID()
	return ref
}

// actorRefMatchesSender enforces full address equality against the reserved
// ActorRef: canonical address, host, port, and name must all match. A sender
// that merely reuses the reserved address string while living at a different
// node or path is rejected fail-closed.
func actorRefMatchesSender(ref *application.DurableActorRef, sender *actor.PID) bool {
	if ref == nil || sender == nil || ref.Address == "" || ref.Host == "" || ref.Name == "" {
		return false
	}
	if sender.ID() != ref.Address {
		return false
	}
	path := sender.Path()
	if path == nil {
		return false
	}
	return path.Host() == ref.Host && path.Port() == ref.Port && path.Name() == ref.Name
}

// cachedActorRef returns the live PID for a previously resolved durable
// reference without touching the actor plane.
func (a *AgentActor) cachedActorRef(address string) *actor.PID {
	if address == "" {
		return nil
	}
	return a.resolvedRefs[address]
}

// resolveActorRefAsync enqueues the re-materialization of a durable actor
// reference into a live PID. Receive paths never block on ActorOf or
// RemoteLookup: the lookup runs detached and reports back through the
// actorRefResolved continuation message, which caches successes and bounds
// failures for every pending completion waiting on that address.
func (a *AgentActor) resolveActorRefAsync(ctx *actor.ReceiveContext, ref application.DurableActorRef) {
	if ref.Address == "" || ref.Name == "" {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), ctx.Self(), &actorRefResolved{address: ref.Address})
		return
	}
	if _, cached := a.resolvedRefs[ref.Address]; cached {
		return
	}
	if _, inFlight := a.resolvingRefs[ref.Address]; inFlight {
		return
	}
	a.resolvingRefs[ref.Address] = struct{}{}
	system := ctx.ActorSystem()
	self := ctx.Self()
	go func() {
		pid := lookupActorRef(system, ref)
		_ = self.Tell(context.Background(), self, &actorRefResolved{address: ref.Address, pid: pid})
	}()
}

// lookupActorRef performs the bounded local-or-remote lookup itself; it runs
// detached from any receive path.
func lookupActorRef(system actor.ActorSystem, ref application.DurableActorRef) *actor.PID {
	if ref.Address == "" || ref.Name == "" {
		return nil
	}
	resolveCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	var pid *actor.PID
	if ref.Host == system.Host() && ref.Port == system.Port() {
		if resolved, err := system.ActorOf(resolveCtx, ref.Name); err == nil {
			pid = resolved
		}
	} else if noSender := system.NoSender(); noSender != nil {
		if resolved, err := noSender.RemoteLookup(resolveCtx, ref.Host, ref.Port, ref.Name); err == nil {
			pid = resolved
		}
	}
	return pid
}

// actorRefResolved is the async continuation of resolveActorRefAsync: cache
// the resolved PID, or count one bounded attempt for every pending completion
// whose source address failed to resolve so they still retire eventually.
func (a *AgentActor) actorRefResolved(ctx *actor.ReceiveContext, message *actorRefResolved) {
	if message == nil {
		return
	}
	delete(a.resolvingRefs, message.address)
	if message.pid != nil {
		a.resolvedRefs[message.address] = message.pid
		return
	}
	if a.durablePending != nil || a.durableFailed != nil {
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &actorRefResolved{address: message.address}, ctx.Self(), 10*time.Millisecond)
		return
	}
	old := a.durableState()
	changed := false
	for _, key := range append([]string(nil), a.completionTellOrder...) {
		pending, exists := a.completionTellPending[key]
		if !exists || pending.Source.Address != message.address {
			continue
		}
		pending.Attempts++
		if pending.Attempts >= maxCompletionAttempts {
			delete(a.completionTellPending, key)
			a.completionTellOrder = slices.DeleteFunc(a.completionTellOrder, func(id string) bool { return id == key })
		} else {
			a.completionTellPending[key] = pending
		}
		changed = true
	}
	if !changed {
		return
	}
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: old}) {
		return
	}
}

func (a *AgentActor) requestOutboxCredit(ctx *actor.ReceiveContext, target *actor.PID, item application.DurableActorTaskOutboxItem) {
	if target == nil || time.Now().After(item.Deadline) {
		return
	}
	request := &application.RequestTaskCredit{TaskID: item.TaskID, RequestID: item.RequestID, DedupeID: item.DedupeID, ChainID: item.ChainID, Deadline: item.Deadline, PayloadDigest: item.PayloadDigest}
	_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), target, request)
}

func (a *AgentActor) acceptActorTaskWithCredit(ctx *actor.ReceiveContext, message *application.BridgeIntent, replyTo *actor.PID, sourcePeer application.CommunicationPeer, oldDurable application.DurableAgentState) bool {
	if message == nil || replyTo == nil || (message.Mode != application.BridgeMessageTell && message.Mode != application.BridgeMessageAsk && message.Mode != application.BridgeMessagePrompt) || message.SourceMutationSequence == 0 || message.TargetAgentID != a.id || message.SourceAgentID == "" || message.RequestID == "" || message.DedupeID == "" || message.ChainID == "" || message.HopLimit == 0 || time.Now().After(message.Deadline) || len(message.Payload) == 0 || len(message.Payload) > maxBridgePayloadBytes {
		return false
	}
	key, scope := a.actorTaskScope(message.SourceAgentID)
	digest := bridgeIntentDigest(message)
	if result, _, handled := replayMutation(scope, message.SourceMutationSequence, digest); handled {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), replyTo, &application.ActorTaskAccepted{TaskID: actorTaskID(message.SourceAgentID, message.RequestID, message.DedupeID, message.ChainID, message.SourceMutationSequence), TargetAgentID: a.id, Accepted: result.Accepted, Reason: result.Reason})
		return result.Accepted
	}
	if _, duplicate := scope.dedupe[message.DedupeID]; duplicate {
		return false
	}
	if _, repeated := scope.chains[message.ChainID]; repeated {
		return false
	}
	if a.bridgeSession == "" || !a.hostedPiRuntime.BridgeReady || len(a.bridgeDeliveries) >= maxTargetTaskQueueItems {
		return false
	}
	kind, policy := application.BridgeDeliveryNotification, application.BridgeDeliveryIdleElseSteer
	if message.Mode == application.BridgeMessageAsk || message.Mode == application.BridgeMessagePrompt {
		for _, pending := range a.bridgeDeliveries {
			if pending.Kind == application.BridgeDeliveryPrompt {
				return false
			}
		}
		kind, policy = application.BridgeDeliveryPrompt, application.BridgeDeliveryIdleElseFollowUp
	}
	token := a.sourceScopeToken(key, scope)
	if token == "" {
		return false
	}
	a.bridgeSequence++
	targetPeer := application.CommunicationPeer{StableID: a.id, DisplayName: aggregateDisplayName(a.id, a.hostedPiRuntime.DisplayName), Role: aggregateRole(a.id, a.hostedPiRuntime.Role)}
	delivery := application.BridgeDelivery{Sequence: a.bridgeSequence, SourceAgentID: message.SourceAgentID, TargetAgentID: a.id, RequestID: message.RequestID, DedupeID: message.DedupeID, ChainID: message.ChainID, Source: sourcePeer, Target: targetPeer, Deadline: message.Deadline, HopLimit: message.HopLimit - 1, Payload: append([]byte(nil), message.Payload...), Policy: policy, Kind: kind, SourceScope: token, CompletionKey: actorTaskCompletionKey(a.id, a.bridgeSequence, message.SourceAgentID, message.RequestID, message.DedupeID, message.ChainID, message.SourceMutationSequence)}
	a.bridgeDeliveries = append(a.bridgeDeliveries, delivery)
	a.deliverySources[delivery.Sequence] = key
	a.taskSources[delivery.Sequence] = replyTo
	a.durableTaskSources[delivery.Sequence] = actorRefFromPID(message.SourceAgentID, replyTo)
	scope.dedupe[message.DedupeID] = bridgeDedupeRecord{sequence: delivery.Sequence, mutationSequence: message.SourceMutationSequence, chainID: message.ChainID}
	scope.chains[message.ChainID] = struct{}{}
	result := application.BridgeIntentResult{Accepted: true, AwaitingAck: message.Mode == application.BridgeMessageAsk || message.Mode == application.BridgeMessagePrompt}
	recordMutation(scope, message.SourceMutationSequence, digest, result, true, message.DedupeID, message.ChainID)
	accepted := &application.ActorTaskAccepted{TaskID: actorTaskID(message.SourceAgentID, message.RequestID, message.DedupeID, message.ChainID, message.SourceMutationSequence), TargetAgentID: a.id, Accepted: true}
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{sender: replyTo, old: oldDurable, timeoutScope: key, timeoutDedupe: message.DedupeID, timeout: time.Until(message.Deadline), taskAccepted: accepted}) {
		return true
	}
	_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &application.BridgeIntentTimeout{ScopeKey: key, DedupeID: message.DedupeID}, ctx.Self(), max(time.Until(message.Deadline), time.Millisecond))
	_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), replyTo, accepted)
	return true
}

func (a *AgentActor) actorTaskCompleted(ctx *actor.ReceiveContext, message *application.ActorTaskCompleted) {
	if message == nil || message.CompletionKey == "" {
		return
	}
	if _, exists := a.taskCompletions[message.CompletionKey]; exists {
		return
	}
	if a.durablePending != nil || a.durableFailed != nil {
		return
	}
	old := a.durableState()
	copy := *message
	copy.Terminal.Result = append([]byte(nil), message.Terminal.Result...)
	historyKey := actorTaskID(a.id, message.OriginalRequestID, message.DedupeID, message.ChainID, message.SourceMutationSequence)
	a.retainSourceCompletion(historyKey, copy)
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: old, taskCompletionPublish: &copy}) {
		return
	}
	a.publishTaskCompletion(ctx, &copy)
}

func (a *AgentActor) retainSourceCompletion(historyKey string, completion application.ActorTaskCompleted) {
	if completion.CompletionKey == "" || historyKey == "" {
		return
	}
	copy := completion
	copy.Terminal.Result = append([]byte(nil), completion.Terminal.Result...)
	if _, exists := a.taskCompletions[copy.CompletionKey]; !exists {
		a.taskCompletions[copy.CompletionKey] = copy
		a.taskCompletionOrder = append(a.taskCompletionOrder, copy.CompletionKey)
	}
	if _, exists := a.sourceTaskHistory[historyKey]; !exists {
		a.sourceTaskHistory[historyKey] = copy
		a.sourceTaskHistoryOrder = append(a.sourceTaskHistoryOrder, historyKey)
	}
	for len(a.sourceTaskHistoryOrder) > maxCommandResults {
		oldest := a.sourceTaskHistoryOrder[0]
		a.sourceTaskHistoryOrder = a.sourceTaskHistoryOrder[1:]
		delete(a.sourceTaskHistory, oldest)
	}
	for len(a.taskCompletionOrder) > maxCommandResults {
		oldest := a.taskCompletionOrder[0]
		a.taskCompletionOrder = a.taskCompletionOrder[1:]
		delete(a.taskCompletions, oldest)
	}
}

func (a *AgentActor) publishTargetTaskCommitted(ctx *actor.ReceiveContext, message *application.TargetTaskCommitted) {
	if message == nil || message.TargetAgentID == "" {
		return
	}
	if topic := ctx.ActorSystem().TopicActor(); topic != nil {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), topic, actor.NewPublish(message.TaskID, application.TargetTaskCommittedTopic, message))
	}
}

func (a *AgentActor) publishTaskCompletion(ctx *actor.ReceiveContext, message *application.ActorTaskCompleted) {
	if message == nil {
		return
	}
	if topic := ctx.ActorSystem().TopicActor(); topic != nil {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), topic, actor.NewPublish(message.CompletionKey, application.ActorMessageReplyTopic, message))
	}
}

func (a *AgentActor) drainTaskCompletions(message *application.DrainReceivedTaskCompletions) {
	if message == nil || message.Result == nil {
		return
	}
	items := make([]application.ActorTaskCompleted, 0, len(a.taskCompletionOrder))
	for _, key := range a.taskCompletionOrder {
		items = append(items, a.taskCompletions[key])
	}
	select {
	case message.Result <- items:
	default:
	}
}

func (a *AgentActor) bridgeIntent(ctx *actor.ReceiveContext, message *application.BridgeIntent) {
	// Authorization precedes scope lookup, so revoked callers cannot probe a
	// retained result even while their previously accepted delivery is pending.
	if message == nil {
		respondBridgeIntent(ctx, nil, &application.BridgeIntentResult{Reason: "invalid, expired, or stale actor message"})
		return
	}
	if message.Mode != application.BridgeMessageTell && message.Mode != application.BridgeMessageAsk && message.Mode != application.BridgeMessagePrompt || message.SourceMutationSequence == 0 || message.TargetAgentID != a.id || message.SourceAgentID == "" || message.RequestID == "" || message.DedupeID == "" || message.ChainID == "" || message.HopLimit == 0 || time.Now().After(message.Deadline) || len(message.Payload) == 0 || len(message.Payload) > maxBridgePayloadBytes || !a.validHandle(message.SessionID, message.GenerationID, message.Principal, message.Handle, message.Fence, message.RequiredCapability) {
		respondBridgeIntent(ctx, message.Receipt, &application.BridgeIntentResult{Reason: "invalid, expired, or stale actor message"})
		return
	}
	if a.durablePending != nil || a.durableFailed != nil {
		respondBridgeIntent(ctx, message.Receipt, &application.BridgeIntentResult{Reason: "durable persistence is busy"})
		return
	}
	key, scope := a.sourceMutationScope(message.SessionID, message.GenerationID, message.Principal, message.Fence)
	digest := bridgeIntentDigest(message)
	if result, pending, handled := replayMutation(scope, message.SourceMutationSequence, digest); handled {
		if pending && (message.Mode == application.BridgeMessageAsk || message.Mode == application.BridgeMessagePrompt) {
			scope.asks[message.DedupeID] = pendingBridgeAsk{completion: message.Completion}
		}
		respondBridgeIntent(ctx, message.Receipt, result)
		return
	}
	complete := func(result application.BridgeIntentResult) { respondBridgeIntent(ctx, message.Receipt, &result) }
	if _, duplicate := scope.dedupe[message.DedupeID]; duplicate {
		complete(application.BridgeIntentResult{Reason: "delivery dedupe identity repeated"})
		return
	}
	if _, repeated := scope.chains[message.ChainID]; repeated {
		complete(application.BridgeIntentResult{Reason: "delivery chain identity repeated"})
		return
	}
	if a.bridgeSession == "" || !a.hostedPiRuntime.BridgeReady {
		complete(application.BridgeIntentResult{Reason: "target hosted bridge is not ready"})
		return
	}
	if len(a.bridgeDeliveries) >= maxBridgeItems {
		complete(application.BridgeIntentResult{Reason: "target delivery backlog is full"})
		return
	}
	kind, policy := application.BridgeDeliveryNotification, application.BridgeDeliveryIdleElseSteer
	if message.Mode == application.BridgeMessageAsk || message.Mode == application.BridgeMessagePrompt {
		for _, pending := range a.bridgeDeliveries {
			if pending.Kind == application.BridgeDeliveryPrompt {
				complete(application.BridgeIntentResult{Reason: "target already has a model task in progress"})
				return
			}
		}
		kind, policy = application.BridgeDeliveryPrompt, application.BridgeDeliveryIdleElseFollowUp
	}
	token := a.sourceScopeToken(key, scope)
	if token == "" {
		complete(application.BridgeIntentResult{Reason: "source scope ledger is full"})
		return
	}
	oldDurable := a.durableState()
	a.bridgeSequence++
	delivery := application.BridgeDelivery{Sequence: a.bridgeSequence, SourceAgentID: message.SourceAgentID, TargetAgentID: a.id, RequestID: message.RequestID, DedupeID: message.DedupeID, ChainID: message.ChainID, Deadline: message.Deadline, HopLimit: message.HopLimit - 1, Payload: append([]byte(nil), message.Payload...), Policy: policy, Kind: kind, SourceScope: token, CompletionKey: actorTaskCompletionKey(a.id, a.bridgeSequence, message.Principal, message.RequestID, message.DedupeID, message.ChainID, message.SourceMutationSequence)}
	a.bridgeDeliveries = append(a.bridgeDeliveries, delivery)
	a.deliverySources[delivery.Sequence] = key
	scope.dedupe[message.DedupeID] = bridgeDedupeRecord{sequence: delivery.Sequence, mutationSequence: message.SourceMutationSequence, chainID: message.ChainID}
	scope.chains[message.ChainID] = struct{}{}
	result := application.BridgeIntentResult{Accepted: true, AwaitingAck: message.Mode == application.BridgeMessageAsk || message.Mode == application.BridgeMessagePrompt}
	recordMutation(scope, message.SourceMutationSequence, digest, result, true, message.DedupeID, message.ChainID)
	if message.Mode == application.BridgeMessageAsk || message.Mode == application.BridgeMessagePrompt {
		scope.asks[message.DedupeID] = pendingBridgeAsk{completion: message.Completion}
	}
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{sender: ctx.Sender(), old: oldDurable, intent: &result, intentCompletion: message.Receipt, timeoutScope: key, timeoutDedupe: message.DedupeID, timeout: time.Until(message.Deadline), askScope: key, askDedupe: message.DedupeID, removeAskOnFailure: message.Mode == application.BridgeMessageAsk || message.Mode == application.BridgeMessagePrompt}) {
		return
	}
	_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &application.BridgeIntentTimeout{ScopeKey: key, DedupeID: message.DedupeID}, ctx.Self(), max(time.Until(message.Deadline), time.Millisecond))
	respondBridgeIntent(ctx, message.Receipt, &result)
}

func (a *AgentActor) bridgeIntentFromActorTask(ctx *actor.ReceiveContext, message *application.BridgeIntent, replyTo *actor.PID, sourcePeer application.CommunicationPeer) {
	if message == nil || replyTo == nil || (message.Mode != application.BridgeMessageTell && message.Mode != application.BridgeMessageAsk && message.Mode != application.BridgeMessagePrompt) || message.SourceMutationSequence == 0 || message.TargetAgentID != a.id || message.SourceAgentID == "" || message.RequestID == "" || message.DedupeID == "" || message.ChainID == "" || message.HopLimit == 0 || time.Now().After(message.Deadline) || len(message.Payload) == 0 || len(message.Payload) > maxBridgePayloadBytes {
		respondBridgeIntent(ctx, message.Receipt, &application.BridgeIntentResult{Reason: "invalid, expired, or stale actor task"})
		return
	}
	if a.durablePending != nil || a.durableFailed != nil {
		respondBridgeIntent(ctx, message.Receipt, &application.BridgeIntentResult{Reason: "durable persistence is busy"})
		return
	}
	key, scope := a.actorTaskScope(message.SourceAgentID)
	digest := bridgeIntentDigest(message)
	if result, _, handled := replayMutation(scope, message.SourceMutationSequence, digest); handled {
		respondBridgeIntent(ctx, message.Receipt, result)
		return
	}
	complete := func(result application.BridgeIntentResult) { respondBridgeIntent(ctx, message.Receipt, &result) }
	if _, duplicate := scope.dedupe[message.DedupeID]; duplicate {
		complete(application.BridgeIntentResult{Reason: "delivery dedupe identity repeated"})
		return
	}
	if _, repeated := scope.chains[message.ChainID]; repeated {
		complete(application.BridgeIntentResult{Reason: "delivery chain identity repeated"})
		return
	}
	if a.bridgeSession == "" || !a.hostedPiRuntime.BridgeReady {
		complete(application.BridgeIntentResult{Reason: "target hosted bridge is not ready"})
		return
	}
	if len(a.bridgeDeliveries) >= maxBridgeItems {
		complete(application.BridgeIntentResult{Reason: "target delivery backlog is full"})
		return
	}
	kind, policy := application.BridgeDeliveryNotification, application.BridgeDeliveryIdleElseSteer
	if message.Mode == application.BridgeMessageAsk || message.Mode == application.BridgeMessagePrompt {
		for _, pending := range a.bridgeDeliveries {
			if pending.Kind == application.BridgeDeliveryPrompt {
				complete(application.BridgeIntentResult{Reason: "target already has a model task in progress"})
				return
			}
		}
		kind, policy = application.BridgeDeliveryPrompt, application.BridgeDeliveryIdleElseFollowUp
	}
	token := a.sourceScopeToken(key, scope)
	if token == "" {
		complete(application.BridgeIntentResult{Reason: "source scope ledger is full"})
		return
	}
	oldDurable := a.durableState()
	a.bridgeSequence++
	targetPeer := application.CommunicationPeer{StableID: a.id, DisplayName: aggregateDisplayName(a.id, a.hostedPiRuntime.DisplayName), Role: aggregateRole(a.id, a.hostedPiRuntime.Role)}
	delivery := application.BridgeDelivery{Sequence: a.bridgeSequence, SourceAgentID: message.SourceAgentID, TargetAgentID: a.id, RequestID: message.RequestID, DedupeID: message.DedupeID, ChainID: message.ChainID, Source: sourcePeer, Target: targetPeer, Deadline: message.Deadline, HopLimit: message.HopLimit - 1, Payload: append([]byte(nil), message.Payload...), Policy: policy, Kind: kind, SourceScope: token, CompletionKey: actorTaskCompletionKey(a.id, a.bridgeSequence, message.SourceAgentID, message.RequestID, message.DedupeID, message.ChainID, message.SourceMutationSequence)}
	a.bridgeDeliveries = append(a.bridgeDeliveries, delivery)
	a.deliverySources[delivery.Sequence] = key
	a.taskSources[delivery.Sequence] = replyTo
	a.durableTaskSources[delivery.Sequence] = actorRefFromPID(message.SourceAgentID, replyTo)
	scope.dedupe[message.DedupeID] = bridgeDedupeRecord{sequence: delivery.Sequence, mutationSequence: message.SourceMutationSequence, chainID: message.ChainID}
	scope.chains[message.ChainID] = struct{}{}
	result := application.BridgeIntentResult{Accepted: true, AwaitingAck: message.Mode == application.BridgeMessageAsk || message.Mode == application.BridgeMessagePrompt}
	recordMutation(scope, message.SourceMutationSequence, digest, result, true, message.DedupeID, message.ChainID)
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{sender: ctx.Sender(), old: oldDurable, intent: &result, intentCompletion: message.Receipt, timeoutScope: key, timeoutDedupe: message.DedupeID, timeout: time.Until(message.Deadline), removeAskOnFailure: false}) {
		return
	}
	_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &application.BridgeIntentTimeout{ScopeKey: key, DedupeID: message.DedupeID}, ctx.Self(), max(time.Until(message.Deadline), time.Millisecond))
	respondBridgeIntent(ctx, message.Receipt, &result)
}

func (a *AgentActor) bridgeControl(ctx *actor.ReceiveContext, message *application.BridgeControl) {
	capability, kind := "control_abort", application.BridgeDeliveryAbort
	if message != nil && message.Intent == application.BridgeControlShutdown {
		capability, kind = "control_shutdown", application.BridgeDeliveryShutdown
	}
	if message == nil {
		respondBridgeIntent(ctx, nil, &application.BridgeIntentResult{Reason: "control capability denied or stale handle"})
		return
	}
	if message.Intent != application.BridgeControlAbort && message.Intent != application.BridgeControlShutdown || message.SourceMutationSequence == 0 || message.TargetAgentID != a.id || message.SourceAgentID == "" || message.RequestID == "" || message.DedupeID == "" || message.ChainID == "" || message.HopLimit == 0 || time.Now().After(message.Deadline) || !a.validHandle(message.SessionID, message.GenerationID, message.Principal, message.Handle, message.Fence, capability) {
		respondBridgeIntent(ctx, message.Completion, &application.BridgeIntentResult{Reason: "control capability denied or stale handle"})
		return
	}
	if a.durablePending != nil || a.durableFailed != nil {
		respondBridgeIntent(ctx, message.Completion, &application.BridgeIntentResult{Reason: "durable persistence is busy"})
		return
	}
	key, scope := a.controlMutationScope(message.SessionID, message.GenerationID, message.Principal, message.Fence)
	if scope.highWater == 0 && len(scope.results) == 0 && message.SourceMutationSequence > 1 {
		scope.highWater = message.SourceMutationSequence - 1
	}
	digest := bridgeControlDigest(message)
	if result, _, handled := replayMutation(scope, message.SourceMutationSequence, digest); handled {
		respondBridgeIntent(ctx, message.Completion, result)
		return
	}
	complete := func(result application.BridgeIntentResult) { respondBridgeIntent(ctx, message.Completion, &result) }
	if _, duplicate := scope.dedupe[message.DedupeID]; duplicate {
		complete(application.BridgeIntentResult{Reason: "delivery dedupe identity repeated"})
		return
	}
	if _, repeated := scope.chains[message.ChainID]; repeated {
		complete(application.BridgeIntentResult{Reason: "delivery chain identity repeated"})
		return
	}
	if a.bridgeSession == "" || !a.hostedPiRuntime.BridgeReady || len(a.bridgeDeliveries) >= maxBridgeItems {
		complete(application.BridgeIntentResult{Reason: "target bridge unavailable or overloaded"})
		return
	}
	token := a.sourceScopeToken(key, scope)
	if token == "" {
		complete(application.BridgeIntentResult{Reason: "source scope ledger is full"})
		return
	}
	oldDurable := a.durableState()
	a.bridgeSequence++
	delivery := application.BridgeDelivery{Sequence: a.bridgeSequence, SourceAgentID: message.SourceAgentID, TargetAgentID: a.id, RequestID: message.RequestID, DedupeID: message.DedupeID, ChainID: message.ChainID, Deadline: message.Deadline, HopLimit: message.HopLimit - 1, Kind: kind, SourceScope: token, CompletionKey: actorTaskCompletionKey(a.id, a.bridgeSequence, message.Principal, message.RequestID, message.DedupeID, message.ChainID, message.SourceMutationSequence)}
	a.bridgeDeliveries = append(a.bridgeDeliveries, delivery)
	a.deliverySources[delivery.Sequence] = key
	scope.dedupe[message.DedupeID] = bridgeDedupeRecord{sequence: delivery.Sequence, mutationSequence: message.SourceMutationSequence, chainID: message.ChainID}
	scope.chains[message.ChainID] = struct{}{}
	result := application.BridgeIntentResult{Accepted: true}
	recordMutation(scope, message.SourceMutationSequence, digest, result, true, message.DedupeID, message.ChainID)
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{sender: ctx.Sender(), old: oldDurable, intent: &result, intentCompletion: message.Completion, timeoutScope: key, timeoutDedupe: message.DedupeID, timeout: time.Until(message.Deadline)}) {
		return
	}
	_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &application.BridgeIntentTimeout{ScopeKey: key, DedupeID: message.DedupeID}, ctx.Self(), max(time.Until(message.Deadline), time.Millisecond))
	respondBridgeIntent(ctx, message.Completion, &result)
}

func publishActorReply(system actor.ActorSystem, self *actor.PID, message *application.RemoteBridgeIntent, result application.BridgeIntentResult) {
	if system.TopicActor() == nil || self == nil || message == nil || message.ReplyTopic == "" {
		return
	}
	reply := &application.ActorMessageReply{SessionID: message.SessionID, GenerationID: message.GenerationID, Principal: message.Principal, SourceAgentID: message.SourceAgentID, TargetAgentID: message.TargetAgentID, RequestID: message.RequestID, DedupeID: message.DedupeID, ChainID: message.ChainID, SourceMutationSequence: message.SourceMutationSequence, Mode: message.Mode, Result: result}
	id := fmt.Sprintf("%s:%s:%d", message.SessionID, message.RequestID, message.SourceMutationSequence)
	_ = self.Tell(context.Background(), system.TopicActor(), actor.NewPublish(id, message.ReplyTopic, reply))
}

func isNoSender(ctx *actor.ReceiveContext, sender *actor.PID) bool {
	if sender == nil {
		return false
	}
	return sender.Equals(ctx.ActorSystem().NoSender())
}

func ackDeliveryKind(label string) application.BridgeDeliveryKind {
	switch label {
	case "notification":
		return application.BridgeDeliveryNotification
	case "abort":
		return application.BridgeDeliveryAbort
	case "shutdown":
		return application.BridgeDeliveryShutdown
	case "prompt":
		return application.BridgeDeliveryPrompt
	default:
		return 0
	}
}

func actorTaskCompletionKey(target string, sequence uint64, source, requestID, dedupeID, chainID string, mutationSequence uint64) string {
	return fmt.Sprintf("%s:%d:%s:%s:%s:%s:%d", target, sequence, source, requestID, dedupeID, chainID, mutationSequence)
}

func actorTaskID(source, requestID, dedupeID, chainID string, mutationSequence uint64) string {
	return fmt.Sprintf("%s:%s:%s:%d", source, dedupeID, chainID, mutationSequence)
}

func taskCreditID(target, taskID string, epoch uint64) string {
	digest := sha256.Sum256([]byte(fmt.Sprintf("%s:%s:%d", target, taskID, epoch)))
	return hex.EncodeToString(digest[:16])
}

func minTime(left, right time.Time) time.Time {
	if left.Before(right) {
		return left
	}
	return right
}

func (a *AgentActor) communicationPeer() application.CommunicationPeer {
	peer := application.CommunicationPeer{StableID: a.id, DisplayName: aggregateDisplayName(a.id, a.hostedPiRuntime.DisplayName), Role: aggregateRole(a.id, a.hostedPiRuntime.Role)}
	if strings.HasPrefix(a.id, "client:") {
		peer.DisplayName = "PROJECT MANAGER"
		peer.Role = "PROJECT MANAGER"
	}
	return peer
}

func (a *AgentActor) expireTaskCredits() {
	now := time.Now()
	for id, reservation := range a.taskCreditReservations {
		if now.After(reservation.credit.ExpiresAt) {
			delete(a.taskCreditReservations, id)
		}
	}
}

func sourceMutationScopeKey(sessionID, generationID, principal string, fence, incarnation uint64) string {
	return fmt.Sprintf("%d:%s%d:%s%d:%s:%d:%d", len(sessionID), sessionID, len(generationID), generationID, len(principal), principal, fence, incarnation)
}

// newScopeToken mints the opaque server-issued scope token: bounded random
// bytes with no derivable relationship to the identity tuple it names. A mint
// failure fails closed (empty token) rather than degrading to a predictable
// scope identity.
func newScopeToken() string {
	raw := make([]byte, scopeTokenBytes)
	if _, err := rand.Read(raw); err != nil {
		return ""
	}
	return hex.EncodeToString(raw)
}

// sourceScopeToken issues (once per scope) the opaque token that names a
// mutation scope on serialized surfaces. Raw identity tuples never enter a
// delivery or acknowledgement: the internal scope key stays private to owner
// state and the server-side token-to-key mapping.
func (a *AgentActor) sourceScopeToken(key string, scope *mutationScope) string {
	if scope == nil || key == "" {
		return ""
	}
	if scope.token != "" {
		return scope.token
	}
	if len(a.scopeTokens) >= maxScopeTokens {
		return ""
	}
	token := newScopeToken()
	if token == "" || len(token) > maxScopeTokenLength {
		return ""
	}
	scope.token = token
	a.scopeTokens[token] = key
	return token
}
func (a *AgentActor) sourceMutationScope(sessionID, generationID, principal string, fence uint64) (string, *mutationScope) {
	key := sourceMutationScopeKey(sessionID, generationID, principal, fence, a.hostedPiRuntime.Incarnation)
	scope := a.mutationScopes[key]
	if scope == nil {
		scope = &mutationScope{sessionID: sessionID, generationID: generationID, principal: principal, fence: fence, incarnation: a.hostedPiRuntime.Incarnation, results: make(map[uint64]mutationRecord), dedupe: make(map[string]bridgeDedupeRecord), chains: make(map[string]struct{}), asks: make(map[string]pendingBridgeAsk)}
		a.mutationScopes[key] = scope
	}
	return key, scope
}
func (a *AgentActor) controlMutationScope(sessionID, generationID, principal string, fence uint64) (string, *mutationScope) {
	key := sourceMutationScopeKey(sessionID+"#control", generationID, principal, fence, a.hostedPiRuntime.Incarnation)
	scope := a.mutationScopes[key]
	if scope == nil {
		scope = &mutationScope{sessionID: sessionID + "#control", generationID: generationID, principal: principal, fence: fence, incarnation: a.hostedPiRuntime.Incarnation, results: make(map[uint64]mutationRecord), dedupe: make(map[string]bridgeDedupeRecord), chains: make(map[string]struct{}), asks: make(map[string]pendingBridgeAsk)}
		a.mutationScopes[key] = scope
	}
	return key, scope
}

func (a *AgentActor) actorTaskScope(sourceAgentID string) (string, *mutationScope) {
	key := sourceMutationScopeKey("actor", "actor", sourceAgentID, 0, a.hostedPiRuntime.Incarnation)
	scope := a.mutationScopes[key]
	if scope == nil {
		scope = &mutationScope{sessionID: "actor", generationID: "actor", principal: sourceAgentID, incarnation: a.hostedPiRuntime.Incarnation, results: make(map[uint64]mutationRecord), dedupe: make(map[string]bridgeDedupeRecord), chains: make(map[string]struct{}), asks: make(map[string]pendingBridgeAsk)}
		a.mutationScopes[key] = scope
	}
	return key, scope
}
func replayMutation(scope *mutationScope, sequence uint64, digest [32]byte) (*application.BridgeIntentResult, bool, bool) {
	if sequence > scope.highWater {
		if sequence != scope.highWater+1 {
			return &application.BridgeIntentResult{Reason: "source mutation sequence must advance exactly once"}, false, true
		}
		return nil, false, false
	}
	record, retained := scope.results[sequence]
	if !retained {
		return &application.BridgeIntentResult{Reason: "source mutation sequence is at or below the retired high-water mark"}, false, true
	}
	if record.digest != digest {
		return &application.BridgeIntentResult{Reason: "source mutation sequence collision"}, false, true
	}
	copy := record.result
	return &copy, record.pending, true
}
func recordMutation(scope *mutationScope, sequence uint64, digest [32]byte, result application.BridgeIntentResult, pending bool, dedupeID, chainID string) {
	scope.highWater = sequence
	scope.results[sequence] = mutationRecord{digest: digest, pending: pending, result: result, dedupeID: dedupeID, chainID: chainID}
	scope.order = append(scope.order, sequence)
	if !pending {
		scope.completed++
	}
	retireMutationResults(scope)
}

func mutationDigest(parts ...[]byte) [32]byte {
	hash := sha256.New()
	var size [8]byte
	for _, part := range parts {
		binary.BigEndian.PutUint64(size[:], uint64(len(part)))
		_, _ = hash.Write(size[:])
		_, _ = hash.Write(part)
	}
	var result [32]byte
	copy(result[:], hash.Sum(nil))
	return result
}
func bridgeIntentDigest(message *application.BridgeIntent) [32]byte {
	return mutationDigest([]byte(fmt.Sprint(message.Mode)), []byte(message.SourceAgentID), []byte(message.TargetAgentID), []byte(message.DedupeID), []byte(message.ChainID), []byte(fmt.Sprint(message.HopLimit)), message.Payload)
}
func bridgeControlDigest(message *application.BridgeControl) [32]byte {
	return mutationDigest([]byte(fmt.Sprint(message.Intent)), []byte(message.SourceAgentID), []byte(message.TargetAgentID), []byte(message.DedupeID), []byte(message.ChainID), []byte(fmt.Sprint(message.HopLimit)))
}

func (a *AgentActor) bridgeDeliveryAck(ctx *actor.ReceiveContext, message *application.BridgeDeliveryAck) {
	if message == nil {
		respondBridgeAck(ctx, nil, &application.BridgeDeliveryAckResult{Reason: "delivery acknowledgement fence rejected"})
		return
	}
	if message.Delivered && len(message.Result) > maxBridgePayloadBytes {
		respondBridgeAck(ctx, message.Completion, &application.BridgeDeliveryAckResult{Reason: "delivery result exceeds bound"})
		return
	}
	if message.SessionID != a.bridgeSession || message.GenerationID != a.bridgeGeneration || message.Principal != a.bridgePrincipal || message.Handle != a.bridgeHandle || message.Fence != a.bridgeFence || !a.validHandle(message.SessionID, message.GenerationID, message.Principal, message.Handle, message.Fence, "hosted_bridge") {
		respondBridgeAck(ctx, message.Completion, &application.BridgeDeliveryAckResult{Reason: "delivery acknowledgement fence rejected"})
		return
	}
	if a.durablePending != nil || a.durableFailed != nil {
		respondBridgeAck(ctx, message.Completion, &application.BridgeDeliveryAckResult{Reason: "durable persistence is busy", Cursor: a.ackCursor})
		return
	}
	// Duplicate of an already-contiguously-committed acknowledgement: return the
	// retained terminal on exact identity match and fail closed on collision.
	if message.Sequence <= a.ackCursor {
		record, retained := a.committedAcks[message.Sequence]
		if !retained {
			respondBridgeAck(ctx, message.Completion, &application.BridgeDeliveryAckResult{Reason: "delivery acknowledgement is not retained"})
			return
		}
		if message.DedupeID != record.DedupeID || message.CompletionKey != record.CompletionKey || message.SourceScope != record.SourceScope || message.Kind != application.BridgeDeliveryKindLabel(record.Kind) || message.RuntimeID != record.RuntimeID || message.Incarnation != record.Incarnation || message.PiSessionID != record.PiSessionID || message.Delivered != record.Delivered {
			respondBridgeAck(ctx, message.Completion, &application.BridgeDeliveryAckResult{Reason: "delivery acknowledgement identity collision"})
			return
		}
		respondBridgeAck(ctx, message.Completion, &application.BridgeDeliveryAckResult{Accepted: true, Reason: record.Reason, Cursor: a.ackCursor})
		return
	}
	// Idempotent re-acknowledgement of an already-buffered gap entry.
	if buffered, exists := a.ackGaps[message.Sequence]; exists {
		if message.DedupeID != buffered.DedupeID || message.CompletionKey != buffered.CompletionKey || message.SourceScope != buffered.SourceScope || message.Kind != buffered.Kind || message.RuntimeID != buffered.RuntimeID || message.Incarnation != buffered.Incarnation || message.PiSessionID != buffered.PiSessionID || message.Delivered != buffered.Delivered {
			respondBridgeAck(ctx, message.Completion, &application.BridgeDeliveryAckResult{Reason: "delivery acknowledgement identity collision"})
			return
		}
		respondBridgeAck(ctx, message.Completion, &application.BridgeDeliveryAckResult{Accepted: true, Reason: "acknowledgement buffered behind cursor gap", Cursor: a.ackCursor})
		return
	}
	index := slices.IndexFunc(a.bridgeDeliveries, func(item application.BridgeDelivery) bool {
		return item.Sequence == message.Sequence
	})
	if index < 0 {
		respondBridgeAck(ctx, message.Completion, &application.BridgeDeliveryAckResult{Reason: "delivery is not retained"})
		return
	}
	delivery := a.bridgeDeliveries[index]
	// Fail-closed identity enforcement before any effects: the acknowledgement
	// must name the exact runtime, incarnation, Pi session, delivery kind,
	// source scope, sequence, dedupe identity, and completion key.
	if !a.validAckIdentity(message, &delivery) {
		respondBridgeAck(ctx, message.Completion, &application.BridgeDeliveryAckResult{Reason: "delivery acknowledgement identity rejected"})
		return
	}
	if message.Sequence > a.ackCursor+1 {
		if len(a.ackGaps) >= maxAckGapBuffer {
			respondBridgeAck(ctx, message.Completion, &application.BridgeDeliveryAckResult{Reason: "acknowledgement gap buffer is full"})
			return
		}
		oldDurable := a.durableState()
		buffered := *message
		buffered.Completion = nil
		a.ackGaps[message.Sequence] = buffered
		burst := &ackBurstReceipt{response: message.Completion, result: application.BridgeDeliveryAckResult{Accepted: true, Reason: "acknowledgement buffered behind cursor gap", Cursor: a.ackCursor}}
		if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: oldDurable, ackBurst: burst}) {
			return
		}
		respondBridgeAck(ctx, message.Completion, &burst.result)
		return
	}
	a.commitContiguousAcks(ctx, message)
}

func (a *AgentActor) validAckIdentity(message *application.BridgeDeliveryAck, delivery *application.BridgeDelivery) bool {
	// SourceScope is the opaque server-issued scope token: equality proves the
	// acknowledgement names the exact scope that issued the delivery without
	// exposing the underlying identity tuple.
	return delivery.SourceScope != "" && delivery.CompletionKey != "" &&
		message.DedupeID == delivery.DedupeID &&
		message.RuntimeID == a.hostedPiRuntime.RuntimeID &&
		message.Incarnation == a.hostedPiRuntime.Incarnation &&
		message.PiSessionID == a.bridgePiSession &&
		message.Kind == application.BridgeDeliveryKindLabel(delivery.Kind) &&
		message.SourceScope == delivery.SourceScope &&
		message.CompletionKey == delivery.CompletionKey
}

// commitContiguousAcks commits the triggering acknowledgement when it extends
// the contiguous cursor and then drains every buffered acknowledgement that
// became contiguous, with one durable persist covering the whole burst.
func (a *AgentActor) commitContiguousAcks(ctx *actor.ReceiveContext, trigger *application.BridgeDeliveryAck) {
	oldDurable := a.durableState()
	liveTaskSources := a.cloneTaskSources()
	burst := &ackBurstReceipt{response: trigger.Completion, result: application.BridgeDeliveryAckResult{Accepted: true}}
	ack := trigger
	for ack != nil {
		if !a.commitAck(ctx, ack, burst) {
			a.restoreDurableState(oldDurable)
			respondBridgeAck(ctx, trigger.Completion, &application.BridgeDeliveryAckResult{Reason: "delivery acknowledgement identity rejected", Cursor: a.ackCursor})
			return
		}
		delete(a.ackGaps, ack.Sequence)
		next, buffered := a.ackGaps[ack.Sequence+1]
		ack = nil
		if buffered {
			ack = &next
		}
	}
	burst.result.Cursor = a.ackCursor
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: oldDurable, ackBurst: burst, liveTaskSources: liveTaskSources}) {
		return
	}
	a.deliverAckBurstEffects(ctx, burst)
	respondBridgeAck(ctx, trigger.Completion, &burst.result)
}

func (a *AgentActor) commitAck(ctx *actor.ReceiveContext, message *application.BridgeDeliveryAck, burst *ackBurstReceipt) bool {
	index := slices.IndexFunc(a.bridgeDeliveries, func(item application.BridgeDelivery) bool {
		return item.Sequence == message.Sequence
	})
	if index < 0 {
		return false
	}
	delivery := a.bridgeDeliveries[index]
	if !a.validAckIdentity(message, &delivery) {
		return false
	}
	key := a.deliverySources[message.Sequence]
	scope := a.mutationScopes[key]
	if scope == nil {
		return false
	}
	// Fail closed unless the delivery's scope token maps back to the exact
	// internal scope that owns its mutation state.
	if a.scopeTokens[delivery.SourceScope] != key {
		return false
	}
	record, ok := scope.dedupe[message.DedupeID]
	if !ok || record.sequence != message.Sequence {
		return false
	}
	deliveryKind := delivery.Kind
	result := application.BridgeIntentResult{Accepted: true, Completed: message.Delivered, Reason: message.Reason}
	if message.Delivered {
		if deliveryKind == application.BridgeDeliveryPrompt {
			if len(message.Result) == 0 {
				return false
			}
			result.Result = append([]byte(nil), message.Result...)
		} else {
			result.Result = []byte("delivery acknowledged")
		}
	}
	a.bridgeDeliveries = append(a.bridgeDeliveries[:index], a.bridgeDeliveries[index+1:]...)
	delete(a.deliverySources, message.Sequence)
	replyTo := a.taskSources[message.Sequence]
	sourceRef, hasSourceRef := a.durableTaskSources[message.Sequence]
	delete(a.taskSources, message.Sequence)
	delete(a.durableTaskSources, message.Sequence)
	if replyTo == nil && hasSourceRef {
		// Resolution is an async continuation: enqueue the lookup instead of
		// blocking the acknowledgement commit on the actor plane. The retained
		// pending completion tell below is delivered by the bounded redrive loop.
		a.resolveActorRefAsync(ctx, sourceRef)
	}
	mutation := scope.results[record.mutationSequence]
	mutation.pending, mutation.result = false, result
	scope.results[record.mutationSequence] = mutation
	scope.completed++
	delete(scope.dedupe, message.DedupeID)
	delete(scope.chains, record.chainID)
	retireMutationResults(scope)
	effect := ackCommitEffect{scopeKey: key, dedupeID: message.DedupeID, askResult: result}
	if pending, exists := scope.asks[message.DedupeID]; exists {
		effect.askCompletion = pending.completion
		delete(scope.asks, message.DedupeID)
	}
	a.pruneMutationScope(key, scope)
	if replyTo != nil || hasSourceRef || scope.sessionID == "actor" {
		effect.taskCompletion = &application.ActorTaskCompleted{CompletionKey: delivery.CompletionKey, OriginalRequestID: delivery.RequestID, DedupeID: message.DedupeID, ChainID: delivery.ChainID, SourceMutationSequence: record.mutationSequence, Terminal: result, Source: delivery.Source, Target: delivery.Target, Kind: deliveryKind}
		historyKey := actorTaskID(scope.principal, delivery.RequestID, message.DedupeID, delivery.ChainID, record.mutationSequence)
		a.sourceTaskHistory[historyKey] = *effect.taskCompletion
		a.sourceTaskHistoryOrder = append(a.sourceTaskHistoryOrder, historyKey)
		if replyTo == nil {
			effect.taskCompletion = nil
			if hasSourceRef {
				a.retainPendingCompletionTell(delivery.CompletionKey, sourceRef, application.ActorTaskCompleted{CompletionKey: delivery.CompletionKey, OriginalRequestID: delivery.RequestID, DedupeID: message.DedupeID, ChainID: delivery.ChainID, SourceMutationSequence: record.mutationSequence, Terminal: result, Source: delivery.Source, Target: delivery.Target, Kind: deliveryKind})
			}
		}
		effect.taskReplyTo = replyTo
	}
	burst.commits = append(burst.commits, effect)
	a.committedAcks[message.Sequence] = application.DurableBridgeAckRecord{Sequence: message.Sequence, DedupeID: message.DedupeID, Kind: deliveryKind, SourceScope: delivery.SourceScope, CompletionKey: delivery.CompletionKey, RuntimeID: message.RuntimeID, Incarnation: message.Incarnation, PiSessionID: message.PiSessionID, Delivered: message.Delivered, Reason: boundedAckReason(message.Reason), Result: append([]byte(nil), result.Result...)}
	a.committedAckOrder = append(a.committedAckOrder, message.Sequence)
	for len(a.committedAckOrder) > maxCommittedAcks {
		oldest := a.committedAckOrder[0]
		a.committedAckOrder = a.committedAckOrder[1:]
		delete(a.committedAcks, oldest)
	}
	a.ackCursor = message.Sequence
	return true
}

func boundedAckReason(reason string) string {
	if len(reason) > 256 {
		return reason[:256]
	}
	return reason
}

func (a *AgentActor) deliverAckBurstEffects(ctx *actor.ReceiveContext, burst *ackBurstReceipt) {
	for index := range burst.commits {
		effect := &burst.commits[index]
		if effect.askCompletion != nil {
			deliverBridgeIntentResult(effect.askCompletion, effect.askResult)
		}
		if effect.taskReplyTo != nil && effect.taskCompletion != nil {
			if err := ctx.Self().Tell(context.WithoutCancel(ctx.Context()), effect.taskReplyTo, effect.taskCompletion); err != nil {
				// The terminal is durable but the completion Tell failed (for
				// example a restarted peer): retain it durably and redrive.
				a.deferCompletionTell(ctx, effect, err)
			}
		}
	}
}

func retireMutationResults(scope *mutationScope) {
	for scope.completed > maxRecentMutationResults {
		index := slices.IndexFunc(scope.order, func(sequence uint64) bool {
			record, exists := scope.results[sequence]
			return exists && !record.pending
		})
		if index < 0 {
			return
		}
		sequence := scope.order[index]
		delete(scope.results, sequence)
		scope.order = append(scope.order[:index], scope.order[index+1:]...)
		scope.completed--
	}
}
func (a *AgentActor) pruneRevokedMutationScope(sessionID, generationID, principal string, fence uint64) {
	key := sourceMutationScopeKey(sessionID, generationID, principal, fence, a.hostedPiRuntime.Incarnation)
	if scope := a.mutationScopes[key]; scope != nil && len(scope.dedupe) == 0 {
		if scope.token != "" {
			delete(a.scopeTokens, scope.token)
		}
		delete(a.mutationScopes, key)
	}
}
func (a *AgentActor) pruneMutationScope(key string, scope *mutationScope) {
	if len(scope.dedupe) != 0 {
		return
	}
	// Control and actor-task scopes keep their high-water mark after their
	// last delivery retires: a source must never reuse a mutation sequence
	// (its own history enforces that), so the scope must keep advancing.
	if strings.HasSuffix(scope.sessionID, "#control") || scope.sessionID == "actor" {
		return
	}
	attachment, active := a.attachments[generationKey(scope.sessionID, scope.generationID)]
	if !active || attachment.principal != scope.principal || attachment.fence != scope.fence || scope.incarnation != a.hostedPiRuntime.Incarnation {
		if scope.token != "" {
			delete(a.scopeTokens, scope.token)
		}
		delete(a.mutationScopes, key)
	}
}

// applyRuntimeBinding merges a runtime projection advance into owner state.
// It must only be called for non-retiring advances or as part of a transition
// whose retirement effects are handled separately.
func (a *AgentActor) applyRuntimeBinding(message *application.HostedPiRuntimeStateChanged, binding application.HostedPiRuntimeBinding) {
	if binding.AggregateID == "" {
		binding.AggregateID = a.hostedPiRuntime.AggregateID
	}
	if binding.DisplayName == "" {
		binding.DisplayName = a.hostedPiRuntime.DisplayName
	}
	if binding.Role == "" {
		binding.Role = a.hostedPiRuntime.Role
	}
	a.hostedPiRuntime = binding
	if message.Reason != "" {
		a.runtimeFailure = message.Reason
	} else if binding.State != application.HostedPiRuntimeDegraded {
		a.runtimeFailure = ""
	}
	if a.durableRecord != nil {
		a.durableRecord.Binding = binding
		a.durableRecord.LaunchSpec.Incarnation = binding.Incarnation
	}
}

// incarnationRetired performs the whole incarnation-retirement terminal-failure
// batch as one durable transition: the delivery retirement, bridge-binding
// wipe, and binding swap are persisted before any completion effects, redrive
// scheduling, or registry forward fire — the same pattern as ACK commits. A
// crash or persistence failure before the confirm rolls the batch back and
// re-drives the state change instead of emitting effects twice or never.
func (a *AgentActor) incarnationRetired(ctx *actor.ReceiveContext, message *application.HostedPiRuntimeStateChanged, binding application.HostedPiRuntimeBinding) {
	if a.durableFailed != nil {
		return
	}
	if a.durablePending != nil {
		retry := *message
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &retry, ctx.Self(), 10*time.Millisecond)
		return
	}
	old := a.durableState()
	oldBinding := a.hostedPiRuntime
	liveTaskSources := a.cloneTaskSources()
	burst := a.retirePendingBridgeDeliveries(ctx, "hosted runtime incarnation retired")
	a.bridgeSession, a.bridgeGeneration, a.bridgePrincipal, a.bridgeHandle, a.bridgePiSession = "", "", "", "", ""
	a.bridgeFence = 0
	a.bridgeDeclaredReady = false
	a.bridgeLeaseToken++
	a.applyRuntimeBinding(message, binding)
	a.revision++
	forward := *message
	forward.Binding = binding
	receipt := &pendingDurableReceipt{old: old, ackBurst: burst, runtimeStateForward: &forward, runtimeRollbackBinding: &oldBinding, liveTaskSources: liveTaskSources}
	if a.beginDurablePersist(ctx, receipt) {
		return
	}
	a.completeRuntimeStateEffects(ctx, &forward, burst)
}

// completeRuntimeStateEffects fires the post-commit effects of a runtime state
// transition: retirement completion tells, bounded completion redrive, and the
// registry projection forward. burst may be nil when effects were already
// delivered by the durable receipt completion.
func (a *AgentActor) completeRuntimeStateEffects(ctx *actor.ReceiveContext, forward *application.HostedPiRuntimeStateChanged, burst *ackBurstReceipt) {
	if burst != nil {
		a.deliverAckBurstEffects(ctx, burst)
	}
	a.scheduleCompletionRetry(ctx)
	if a.registryPID != nil {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), a.registryPID, forward)
	}
}

func (a *AgentActor) scheduleCompletionRetry(ctx *actor.ReceiveContext) {
	if len(a.completionTellPending) != 0 {
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &retryCompletionTells{}, ctx.Self(), outboxBaseRetryDelay)
	}
}

// retainPendingCompletionTell records a terminal completion whose delivery
// depends on resolving a durable actor reference asynchronously, bounded like
// every other completion redrive window.
func (a *AgentActor) retainPendingCompletionTell(completionKey string, source application.DurableActorRef, completed application.ActorTaskCompleted) {
	if completionKey == "" {
		return
	}
	a.completionTellPending[completionKey] = application.DurablePendingCompletion{CompletionKey: completionKey, Source: source, Completed: completed}
	a.completionTellOrder = append(a.completionTellOrder, completionKey)
	for len(a.completionTellOrder) > maxCompletionTells {
		oldest := a.completionTellOrder[0]
		a.completionTellOrder = a.completionTellOrder[1:]
		delete(a.completionTellPending, oldest)
	}
}

// retirePendingBridgeDeliveries mutates every retained delivery of a retired
// runtime incarnation to its terminal failure and collects the completion
// effects without emitting them: the caller persists the whole batch first and
// releases the collected effects only after the durable confirm.
func (a *AgentActor) retirePendingBridgeDeliveries(ctx *actor.ReceiveContext, reason string) *ackBurstReceipt {
	if reason == "" {
		reason = "delivery failed terminally"
	}
	burst := &ackBurstReceipt{}
	for _, delivery := range append([]application.BridgeDelivery(nil), a.bridgeDeliveries...) {
		key := a.deliverySources[delivery.Sequence]
		scope := a.mutationScopes[key]
		if scope == nil {
			continue
		}
		record, ok := scope.dedupe[delivery.DedupeID]
		if !ok || record.sequence != delivery.Sequence {
			continue
		}
		result := application.BridgeIntentResult{Accepted: true, Reason: reason}
		mutation := scope.results[record.mutationSequence]
		mutation.pending, mutation.result = false, result
		scope.results[record.mutationSequence] = mutation
		scope.completed++
		delete(scope.dedupe, delivery.DedupeID)
		delete(scope.chains, record.chainID)
		retireMutationResults(scope)
		effect := ackCommitEffect{scopeKey: key, dedupeID: delivery.DedupeID, askResult: result}
		if pending, ok := scope.asks[delivery.DedupeID]; ok {
			effect.askCompletion = pending.completion
			delete(scope.asks, delivery.DedupeID)
		}
		replyTo := a.taskSources[delivery.Sequence]
		sourceRef, hasSourceRef := a.durableTaskSources[delivery.Sequence]
		if replyTo == nil && hasSourceRef {
			// Resolution is an async continuation: enqueue the lookup instead of
			// blocking this receive path on the actor plane.
			a.resolveActorRefAsync(ctx, sourceRef)
		}
		if delivery.CompletionKey != "" && (replyTo != nil || hasSourceRef || scope.sessionID == "actor") {
			completed := application.ActorTaskCompleted{CompletionKey: delivery.CompletionKey, OriginalRequestID: delivery.RequestID, DedupeID: delivery.DedupeID, ChainID: delivery.ChainID, SourceMutationSequence: record.mutationSequence, Terminal: result, Source: delivery.Source, Target: delivery.Target, Kind: delivery.Kind}
			historyKey := actorTaskID(scope.principal, delivery.RequestID, delivery.DedupeID, delivery.ChainID, record.mutationSequence)
			a.retainSourceCompletion(historyKey, completed)
			if replyTo != nil {
				effect.taskReplyTo, effect.taskCompletion = replyTo, &completed
			} else if hasSourceRef {
				a.retainPendingCompletionTell(completed.CompletionKey, sourceRef, completed)
			}
		}
		burst.commits = append(burst.commits, effect)
		delete(a.deliverySources, delivery.Sequence)
		delete(a.taskSources, delivery.Sequence)
		delete(a.durableTaskSources, delivery.Sequence)
		a.pruneMutationScope(key, scope)
	}
	a.bridgeDeliveries = nil
	return burst
}

func (a *AgentActor) bridgeIntentTimeout(ctx *actor.ReceiveContext, message *application.BridgeIntentTimeout) {
	if message == nil {
		return
	}
	if a.durableFailed != nil {
		return
	}
	if a.durablePending != nil {
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), message, ctx.Self(), 10*time.Millisecond)
		return
	}
	scope := a.mutationScopes[message.ScopeKey]
	if scope == nil {
		return
	}
	record, exists := scope.dedupe[message.DedupeID]
	if !exists {
		return
	}
	oldDurable := a.durableState()
	liveTaskSources := a.cloneTaskSources()
	index := slices.IndexFunc(a.bridgeDeliveries, func(item application.BridgeDelivery) bool {
		return item.Sequence == record.sequence && item.DedupeID == message.DedupeID
	})
	var delivery application.BridgeDelivery
	if index >= 0 {
		delivery = a.bridgeDeliveries[index]
		a.bridgeDeliveries = append(a.bridgeDeliveries[:index], a.bridgeDeliveries[index+1:]...)
	}
	delete(a.deliverySources, record.sequence)
	replyTo := a.taskSources[record.sequence]
	sourceRef, hasSourceRef := a.durableTaskSources[record.sequence]
	delete(a.taskSources, record.sequence)
	delete(a.durableTaskSources, record.sequence)
	if replyTo == nil && hasSourceRef {
		// Resolution is an async continuation: enqueue the lookup instead of
		// blocking the deadline-failure path on the actor plane.
		a.resolveActorRefAsync(ctx, sourceRef)
	}
	result := application.BridgeIntentResult{Accepted: true, Reason: "delivery acknowledgement deadline expired"}
	mutation := scope.results[record.mutationSequence]
	mutation.pending, mutation.result = false, result
	scope.results[record.mutationSequence] = mutation
	scope.completed++
	delete(scope.dedupe, message.DedupeID)
	delete(scope.chains, record.chainID)
	retireMutationResults(scope)
	var askCompletion chan<- application.BridgeIntentResult
	if pending, ok := scope.asks[message.DedupeID]; ok {
		askCompletion = pending.completion
		delete(scope.asks, message.DedupeID)
	}
	a.pruneMutationScope(message.ScopeKey, scope)
	var burst *ackBurstReceipt
	if delivery.CompletionKey != "" && (replyTo != nil || hasSourceRef || scope.sessionID == "actor") {
		completed := application.ActorTaskCompleted{CompletionKey: delivery.CompletionKey, OriginalRequestID: delivery.RequestID, DedupeID: message.DedupeID, ChainID: delivery.ChainID, SourceMutationSequence: record.mutationSequence, Terminal: result, Source: delivery.Source, Target: delivery.Target, Kind: delivery.Kind}
		historyKey := actorTaskID(scope.principal, delivery.RequestID, message.DedupeID, delivery.ChainID, record.mutationSequence)
		a.retainSourceCompletion(historyKey, completed)
		burst = &ackBurstReceipt{commits: []ackCommitEffect{{taskReplyTo: replyTo, taskCompletion: &completed}}}
		if replyTo == nil {
			burst.commits[0].taskCompletion = nil
			if hasSourceRef {
				a.retainPendingCompletionTell(completed.CompletionKey, sourceRef, completed)
			}
		}
	}
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: oldDurable, askScope: message.ScopeKey, askDedupe: message.DedupeID, askCompletion: askCompletion, askResult: &result, ackBurst: burst, retryTimeout: true, liveTaskSources: liveTaskSources}) {
		return
	}
	if askCompletion != nil {
		deliverBridgeIntentResult(askCompletion, result)
	}
	if burst != nil {
		a.deliverAckBurstEffects(ctx, burst)
	}
	a.scheduleCompletionRetry(ctx)
}

func (a *AgentActor) pollBridge(ctx *actor.ReceiveContext, message *application.PollBridge) {
	if message == nil {
		ctx.Response(&application.BridgePollResult{Reason: "hosted bridge fence rejected"})
		return
	}
	if a.durablePending != nil || a.durableFailed != nil {
		ctx.Response(&application.BridgePollResult{Reason: "durable state is not committed"})
		return
	}
	exactBridge := message.SessionID == a.bridgeSession && message.GenerationID == a.bridgeGeneration && message.Principal == a.bridgePrincipal && message.Handle == a.bridgeHandle && message.Fence == a.bridgeFence && a.validHandle(message.SessionID, message.GenerationID, message.Principal, message.Handle, message.Fence, "hosted_bridge")
	if exactBridge {
		a.renewBridgeLease(ctx)
	}
	if !exactBridge && !a.validHandle(message.SessionID, message.GenerationID, message.Principal, message.Handle, message.Fence, "observe") {
		ctx.Response(&application.BridgePollResult{Reason: "hosted bridge fence rejected"})
		return
	}
	limit := int(message.MaxItems)
	if limit < 1 || limit > 64 {
		limit = 64
	}
	result := &application.BridgePollResult{LatestSequence: message.AfterSequence}
	type item struct {
		sequence uint64
		event    *application.BridgeEvent
		delivery *application.BridgeDelivery
	}
	items := make([]item, 0, len(a.bridgeEvents)+len(a.bridgeDeliveries))
	plan := a.projections[generationKey(message.SessionID, message.GenerationID)]
	if plan != nil && plan.subscribed && !plan.closing {
		minimumSequence := max(message.AfterSequence, plan.startSequence)
		for index := range a.bridgeEvents {
			if a.bridgeEvents[index].Sequence > minimumSequence {
				items = append(items, item{sequence: a.bridgeEvents[index].Sequence, event: &a.bridgeEvents[index]})
			}
		}
	}
	if exactBridge {
		for index := range a.bridgeDeliveries {
			if a.bridgeDeliveries[index].Sequence > message.AfterSequence {
				items = append(items, item{sequence: a.bridgeDeliveries[index].Sequence, delivery: &a.bridgeDeliveries[index]})
			}
		}
	}
	slices.SortFunc(items, func(left, right item) int {
		if left.sequence < right.sequence {
			return -1
		}
		if left.sequence > right.sequence {
			return 1
		}
		return 0
	})
	for _, candidate := range items[:min(limit, len(items))] {
		result.LatestSequence = candidate.sequence
		if candidate.event != nil {
			result.Events = append(result.Events, *candidate.event)
		} else {
			result.Deliveries = append(result.Deliveries, *candidate.delivery)
		}
	}
	result.More = len(items) > limit
	ctx.Response(result)
}

func (a *AgentActor) recordProjectionEvent(event application.AgentProjectionEvent) {
	a.bridgeSequence++
	a.bridgeEvents = append(a.bridgeEvents, application.BridgeEvent{Sequence: a.bridgeSequence, AgentID: event.AgentID, Revision: event.Revision, Operation: event.Operation})
	if len(a.bridgeEvents) > maxBridgeItems {
		a.bridgeEvents = a.bridgeEvents[1:]
	}
}

func (a *AgentActor) command(ctx *actor.ReceiveContext, message *application.AgentCommand) {
	// AgentCommand is the observed-upstream metadata seam and is not exposed by
	// the hosted protobuf gateway. Hosted-owned mutations use BridgeIntent or
	// BridgeControl so their payload, high-water, and receipt are persisted.
	if a.durableRecord != nil {
		ctx.Response(&application.CommandResult{Reason: "legacy command is unavailable for durable hosted actors"})
		return
	}
	if message == nil || message.RequestID == "" || message.Operation == "" || !a.validHandle(message.SessionID, message.GenerationID, message.Principal, message.Handle, message.Fence, message.Capability) {
		ctx.Response(&application.CommandResult{Reason: "capability denied or stale handle"})
		return
	}
	key := fmt.Sprintf("%s\x00%s\x00%s\x00%s", message.Principal, generationKey(message.SessionID, message.GenerationID), message.Operation, message.RequestID)
	if record, exists := a.commandResults[key]; exists {
		if record.digest != message.PayloadDigest {
			ctx.Response(&application.CommandResult{Reason: "request id payload collision"})
			return
		}
		if record.result == nil {
			ctx.Response(&application.CommandResult{Reason: "request identity is outside the retained result window"})
			return
		}
		copy := *record.result
		ctx.Response(&copy)
		return
	}
	if len(a.commandResults) >= maxCommandIdentities {
		ctx.Response(&application.CommandResult{Reason: "command identity ledger is full"})
		return
	}
	nextSequence, nextRevision := a.commandSequence+1, a.revision+1
	event := &application.AgentProjectionEvent{AgentID: a.id, Revision: nextRevision, CommandSequence: nextSequence, Operation: message.Operation, OriginSessionID: message.SessionID}
	if topic := ctx.ActorSystem().TopicActor(); topic != nil {
		if err := ctx.Self().Tell(context.WithoutCancel(ctx.Context()), topic, actor.NewPublish(key, agentTopic(a.id), event)); err != nil {
			ctx.Response(&application.CommandResult{Reason: "projection publication unavailable"})
			return
		}
	}
	a.commandSequence, a.revision = nextSequence, nextRevision
	result := &application.CommandResult{Completed: true, CommandSequence: a.commandSequence, Revision: a.revision}
	a.commandResults[key] = commandRecord{digest: message.PayloadDigest, result: result}
	a.commandOrder = append(a.commandOrder, key)
	if len(a.commandOrder) > maxCommandResults {
		evicted := a.commandOrder[0]
		record := a.commandResults[evicted]
		record.result = nil
		a.commandResults[evicted] = record
		a.commandOrder = a.commandOrder[1:]
	}
	copy := *result
	ctx.Response(&copy)
}

func (a *AgentActor) dropSession(ctx *actor.ReceiveContext, message *application.DropSession) {
	if a.durableFailed != nil {
		return
	}
	if a.durablePending != nil {
		copy := *message
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &copy, ctx.Self(), 10*time.Millisecond)
		return
	}
	if message.SessionID == a.bridgeSession && message.GenerationID == a.bridgeGeneration && a.authorityBinding.Kind == application.AuthorityBindingHostedOwned && a.runtimePID != nil && a.hostedPiRuntime.State != application.HostedPiRuntimeStopped && a.hostedPiRuntime.State != application.HostedPiRuntimeStopping && a.hostedPiRuntime.State != application.HostedPiRuntimeDegraded {
		// Fail closed instead of wiping a live hosted bridge binding: a session
		// coordination drop (for example a late metadata cleanup retry) must not
		// null the durable bridge binding, revoke its generation, and unlink its
		// attachment while the exact runtime and its Pi WebSocket are still live.
		// Such a wipe is unrecoverable: the reconnected bridge could never
		// reattach, deliveries would stall, and health would stay ready. Only a
		// fenced bridge teardown or a stopped runtime may retire the binding.
		err := fmt.Errorf("refusing live hosted bridge binding drop for session %s", message.SessionID)
		a.durableFailed = errors.Join(a.durableFailed, err)
		a.hostedPiRuntime.State = application.HostedPiRuntimeDegraded
		a.hostedPiRuntime.BridgeReady = false
		a.revision++
		if a.persistenceSupervisor != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), a.persistenceSupervisor, &application.QuarantineDurableHostedState{AgentID: a.id, Reason: "live hosted bridge binding drop refused", Err: err})
		}
		return
	}
	old := a.durableState()
	key := generationKey(message.SessionID, message.GenerationID)
	if _, exists := a.revoked[key]; !exists {
		if len(a.revoked) >= maxRevokedGenerations {
			return
		}
		a.revoked[key] = struct{}{}
	}
	if current, exists := a.attachments[key]; exists {
		a.pruneRevokedMutationScope(message.SessionID, message.GenerationID, current.principal, current.fence)
	}
	delete(a.attachments, key)
	if message.SessionID == a.bridgeSession && message.GenerationID == a.bridgeGeneration {
		a.bridgeSession, a.bridgeGeneration, a.bridgePrincipal, a.bridgeHandle, a.bridgePiSession = "", "", "", "", ""
		a.bridgeFence = 0
		a.bridgeDeclaredReady = false
		a.bridgeLeaseToken++
		a.hostedPiRuntime.BridgeReady = false
		if a.runtimePID != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), a.runtimePID, &application.HostedPiBridgeReadiness{Ready: false})
		}
	}
	drop := projectionDrop{message: *message}
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: old, drop: &drop}) {
		return
	}
	a.continueDrop(ctx, drop)
}

func (a *AgentActor) continueDrop(ctx *actor.ReceiveContext, drop projectionDrop) {
	message := drop.message
	key := generationKey(message.SessionID, message.GenerationID)
	plan := a.projections[key]
	if plan == nil {
		a.ackDrop(ctx, drop)
		return
	}
	plan.closing = true
	plan.drops = append(plan.drops, drop)
	for _, requester := range plan.requesters {
		deliverOperationResult(requester, application.OperationResult{Reason: "session closed before projection subscription completed"})
	}
	plan.requesters = nil
	a.deliverProjectionClose(ctx, key, plan)
}

func (a *AgentActor) deliverProjectionClose(ctx *actor.ReceiveContext, key string, plan *projectionLifecycle) {
	_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), plan.pid, &closeProjection{})
	parts := splitGenerationKey(key)
	_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &retryProjectionClose{sessionID: parts[0], generationID: parts[1]}, ctx.Self(), projectionRetry)
}

func (a *AgentActor) retryProjectionClose(ctx *actor.ReceiveContext, message *retryProjectionClose) {
	key := generationKey(message.sessionID, message.generationID)
	if plan := a.projections[key]; plan != nil && plan.closing {
		a.deliverProjectionClose(ctx, key, plan)
	}
}

func (a *AgentActor) projectionTerminated(ctx *actor.ReceiveContext, message *actor.Terminated) {
	name := message.ActorPath().Name()
	for key, plan := range a.projections {
		if plan.pid.Name() != name {
			continue
		}
		delete(a.projections, key)
		if plan.closing {
			for _, drop := range plan.drops {
				a.ackDrop(ctx, drop)
			}
			for _, requester := range plan.closes {
				deliverOperationResult(requester, application.OperationResult{Completed: true, Revision: a.revision})
			}
		} else {
			for _, requester := range plan.requesters {
				deliverOperationResult(requester, application.OperationResult{Reason: "projection terminated before subscription acknowledgement"})
			}
		}
		return
	}
}

func (a *AgentActor) ackDrop(ctx *actor.ReceiveContext, drop projectionDrop) {
	message := drop.message
	if message.Acknowledge != nil {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), message.Acknowledge, &application.SessionDropped{SessionID: message.SessionID, GenerationID: message.GenerationID, AgentName: message.AgentName})
	} else if message.Result != nil {
		deliverOperationResult(message.Result, application.OperationResult{Completed: true, Revision: a.revision})
	} else {
		ctx.Response(&application.OperationResult{Completed: true, Revision: a.revision})
	}
}

func respondOperation(ctx *actor.ReceiveContext, target chan<- application.OperationResult, result *application.OperationResult) {
	if target != nil {
		deliverOperationResult(target, *result)
	}
	ctx.Response(result)
}
func respondAttach(ctx *actor.ReceiveContext, target chan<- application.AttachResult, result *application.AttachResult) {
	if target != nil {
		deliverAttachResult(target, *result)
	}
	ctx.Response(result)
}
func deliverAttachResult(target chan<- application.AttachResult, result application.AttachResult) {
	if target == nil {
		return
	}
	select {
	case target <- result:
	default:
	}
}
func respondBridge(ctx *actor.ReceiveContext, target chan<- application.BridgeResult, result *application.BridgeResult) {
	if target != nil {
		deliverBridgeResult(target, *result)
	}
	ctx.Response(result)
}
func deliverBridgeResult(target chan<- application.BridgeResult, result application.BridgeResult) {
	if target == nil {
		return
	}
	select {
	case target <- result:
	default:
	}
}
func respondBridgeIntent(ctx *actor.ReceiveContext, target chan<- application.BridgeIntentResult, result *application.BridgeIntentResult) {
	if target != nil {
		deliverBridgeIntentResult(target, *result)
	}
	ctx.Response(result)
}
func respondBridgeAck(ctx *actor.ReceiveContext, target chan<- application.BridgeDeliveryAckResult, result *application.BridgeDeliveryAckResult) {
	if target != nil {
		deliverBridgeAckResult(target, *result)
	}
	ctx.Response(result)
}
func deliverBridgeAckResult(target chan<- application.BridgeDeliveryAckResult, result application.BridgeDeliveryAckResult) {
	if target == nil {
		return
	}
	select {
	case target <- result:
	default:
	}
}
func deliverBridgeIntentResult(target chan<- application.BridgeIntentResult, result application.BridgeIntentResult) {
	if target == nil {
		return
	}
	select {
	case target <- result:
	default:
	}
}

func deliverOperationResult(target chan<- application.OperationResult, result application.OperationResult) {
	if target == nil {
		return
	}
	select {
	case target <- result:
	default:
	}
}

func (a *AgentActor) validHandle(sessionID, generationID, principal, handle string, fence uint64, capability string) bool {
	if a.isRevoked(sessionID, generationID) {
		return false
	}
	current, ok := a.attachments[generationKey(sessionID, generationID)]
	if !ok || current.principal != principal || current.handle != handle || current.fence != fence {
		return false
	}
	if capability == "" {
		return true
	}
	_, ok = current.capabilities[capability]
	return ok
}
func (a *AgentActor) isRevoked(sessionID, generationID string) bool {
	if sessionID == "" || generationID == "" {
		return true
	}
	_, revoked := a.revoked[generationKey(sessionID, generationID)]
	return revoked
}
func generationKey(sessionID, generationID string) string { return sessionID + "\x00" + generationID }
func splitGenerationKey(key string) [2]string {
	for index := range key {
		if key[index] == 0 {
			return [2]string{key[:index], key[index+1:]}
		}
	}
	return [2]string{key, ""}
}
func agentTopic(agentID string) string { return "subagents.agent." + agentID }
func projectionName(sessionID, generationID string) string {
	digest := sha256.Sum256([]byte(generationKey(sessionID, generationID)))
	return "projection-" + hex.EncodeToString(digest[:8])
}

type projectionActor struct {
	parent                  *actor.PID
	topic                   string
	sessionID, generationID string
	initialDelay            time.Duration
	subscribeStarted        bool
	subscribed              bool
	closing                 bool
	parentObserved          bool
}

func (*projectionActor) PreStart(*actor.Context) error { return nil }
func (*projectionActor) PostStop(*actor.Context) error { return nil }
func (p *projectionActor) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *actor.PostStart:
		if p.initialDelay > 0 {
			p.schedulePubSub(ctx, p.initialDelay)
		} else {
			p.subscribeStarted = true
			p.deliverPubSub(ctx)
		}
	case *retryProjectionPubSub:
		p.subscribeStarted = true
		p.deliverPubSub(ctx)
	case *actor.SubscribeAck:
		if message.Topic() == p.topic {
			p.subscribed = true
			p.deliverPubSub(ctx)
		}
	case *projectionSubscribedObserved:
		p.parentObserved = true
	case *closeProjection:
		p.closing = true
		if p.subscribeStarted {
			p.deliverPubSub(ctx)
		}
	case *actor.UnsubscribeAck:
		if message.Topic() == p.topic && p.closing && p.subscribed {
			ctx.Shutdown()
		}
	case *application.AgentProjectionEvent:
		copy := *message
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), p.parent, &projectionEvent{event: copy})
	default:
		ctx.Unhandled()
	}
}

func (p *projectionActor) deliverPubSub(ctx *actor.ReceiveContext) {
	switch {
	case !p.subscribed:
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), ctx.ActorSystem().TopicActor(), actor.NewSubscribe(p.topic))
		p.schedulePubSub(ctx, projectionRetry)
	case p.closing:
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), ctx.ActorSystem().TopicActor(), actor.NewUnsubscribe(p.topic))
		p.schedulePubSub(ctx, projectionRetry)
	case !p.parentObserved:
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), p.parent, &projectionSubscribed{sessionID: p.sessionID, generationID: p.generationID})
		p.schedulePubSub(ctx, projectionRetry)
	}
}

func (p *projectionActor) schedulePubSub(ctx *actor.ReceiveContext, delay time.Duration) {
	_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &retryProjectionPubSub{}, ctx.Self(), delay)
}
