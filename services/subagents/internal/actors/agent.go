package actors

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"slices"
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
)

type projectionSubscribed struct{ sessionID, generationID string }
type projectionSubscribedObserved struct{}
type projectionEvent struct {
	event application.AgentProjectionEvent
}
type closeProjection struct{}
type retryProjectionPubSub struct{}
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
	ack                         *application.BridgeDeliveryAckResult
	ackCompletion               chan<- application.BridgeDeliveryAckResult
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
	drop                        *projectionDrop
	rollingBack                 bool
	persistErr                  error
}
type pendingBridgeAsk struct {
	completion chan<- application.BridgeIntentResult
}
type mutationScope struct {
	sessionID, generationID, principal string
	fence, incarnation                 uint64
	highWater                          uint64
	results                            map[uint64]mutationRecord
	order                              []uint64
	completed                          int
	dedupe                             map[string]bridgeDedupeRecord
	chains                             map[string]struct{}
	asks                               map[string]pendingBridgeAsk
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

	registryPID           *actor.PID
	runtimePID            *actor.PID
	bridgeSession         string
	bridgeGeneration      string
	bridgePrincipal       string
	bridgeHandle          string
	bridgePiSession       string
	bridgeFence           uint64
	bridgeLeaseToken      uint64
	bridgeDeclaredReady   bool
	bridgeSequence        uint64
	bridgeEvents          []application.BridgeEvent
	bridgeDeliveries      []application.BridgeDelivery
	deliverySources       map[uint64]string
	mutationScopes        map[string]*mutationScope
	persistencePID        *actor.PID
	persistenceSupervisor *actor.PID
	durableRecord         *application.DurableHostedRecord
	durableCorrelation    uint64
	durablePending        *pendingDurableReceipt
	durableFailed         error
}

func NewAgentActor(registration *application.RegisterAgent, registry ...*actor.PID) *AgentActor {
	allowed := make(map[string]struct{}, len(registration.AllowedCapability))
	for _, capability := range registration.AllowedCapability {
		allowed[capability] = struct{}{}
	}
	metadataBinding := registration.HostedPiRuntime
	metadataBinding.DisplayName = registration.DisplayName
	metadataBinding.Role = registration.Role
	value := &AgentActor{id: registration.AgentID, authorityBinding: registration.AuthorityBinding, hostedPiRuntime: metadataBinding, retention: registration.Retention, recovery: registration.Recovery, allowed: allowed, attachments: make(map[string]attachment), revoked: make(map[string]struct{}), revision: 1, commandResults: make(map[string]commandRecord), projections: make(map[string]*projectionLifecycle), deliverySources: make(map[uint64]string), mutationScopes: make(map[string]*mutationScope), persistencePID: registration.PersistencePID, persistenceSupervisor: registration.PersistenceSupervisor, durableRecord: registration.DurableRecord}
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
		ctx.Response(&copy)
	case *application.StartHostedPiRuntime:
		if a.runtimePID != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), a.runtimePID, message)
		}
	case *application.StopHostedPiRuntime:
		if a.runtimePID != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), a.runtimePID, message)
		} else {
			a.hostedPiRuntime.State = application.HostedPiRuntimeDegraded
			a.hostedPiRuntime.BridgeReady = false
			a.revision++
		}
	case *application.HostedPiRuntimeStateChanged:
		a.hostedPiRuntime = message.Binding
		if a.durableRecord != nil {
			a.durableRecord.Binding = message.Binding
		}
		a.revision++
		if a.registryPID != nil {
			copy := *message
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
	case *restoreDurableTimers:
		a.restoreDurableTimers(ctx)
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
	if message == nil || a.runtimePID == nil || message.AgentID != a.id || message.RuntimeID != a.hostedPiRuntime.RuntimeID || message.Incarnation != a.hostedPiRuntime.Incarnation || message.PiSessionID == "" {
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
	state := application.DurableAgentState{Revision: a.revision, CommandSequence: a.commandSequence, Fence: a.fence, BridgeFence: a.bridgeFence, BridgeSequence: a.bridgeSequence, BridgeLeaseToken: a.bridgeLeaseToken, BridgeReady: a.hostedPiRuntime.BridgeReady, BridgeDeclaredReady: a.bridgeDeclaredReady, BridgeSession: a.bridgeSession, BridgeGeneration: a.bridgeGeneration, BridgePrincipal: a.bridgePrincipal, BridgeHandle: a.bridgeHandle, BridgePiSession: a.bridgePiSession, BridgeDeliveries: append([]application.BridgeDelivery(nil), a.bridgeDeliveries...), DeliverySources: make(map[uint64]string, len(a.deliverySources))}
	for sequence, key := range a.deliverySources {
		state.DeliverySources[sequence] = key
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
		durable := application.DurableMutationScope{Key: key, SessionID: scope.sessionID, GenerationID: scope.generationID, Principal: scope.principal, Fence: scope.fence, Incarnation: scope.incarnation, HighWater: scope.highWater, Dedupe: make(map[string]application.DurableDedupeRecord, len(scope.dedupe))}
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
		scope := &mutationScope{sessionID: item.SessionID, generationID: item.GenerationID, principal: item.Principal, fence: item.Fence, incarnation: item.Incarnation, highWater: item.HighWater, results: make(map[uint64]mutationRecord), dedupe: make(map[string]bridgeDedupeRecord), chains: make(map[string]struct{}), asks: make(map[string]pendingBridgeAsk)}
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

func (a *AgentActor) beginDurablePersist(ctx *actor.ReceiveContext, receipt *pendingDurableReceipt) bool {
	if a.durableRecord == nil || a.persistencePID == nil {
		return false
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
	record.Binding = a.hostedPiRuntime
	record.AgentState = state
	if err := ctx.Self().Tell(context.WithoutCancel(ctx.Context()), a.persistencePID, &application.PersistDurableHostedState{Record: record, Owner: ctx.Self(), Correlation: receipt.correlation}); err != nil {
		a.durablePersisted(ctx, &application.DurableHostedStatePersisted{Correlation: receipt.correlation, Err: err})
	}
}

func (a *AgentActor) durablePersisted(ctx *actor.ReceiveContext, message *application.DurableHostedStatePersisted) {
	pending := a.durablePending
	if pending == nil || message.Correlation != pending.correlation {
		return
	}
	if message.Err != nil && !pending.rollingBack {
		asks := a.snapshotPendingAsks()
		readyAfterEffect := a.hostedPiRuntime.BridgeReady
		a.restoreDurableState(pending.old)
		if !readyAfterEffect {
			a.hostedPiRuntime.BridgeReady = false
		}
		if a.runtimePID == nil {
			a.hostedPiRuntime.State = application.HostedPiRuntimeDegraded
			a.hostedPiRuntime.BridgeReady = false
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
		if pending.ack != nil {
			pending.ack = &application.BridgeDeliveryAckResult{Reason: "durable acknowledgement persistence failed"}
		}
	} else if pending.askCompletion != nil && pending.askResult != nil {
		deliverBridgeIntentResult(pending.askCompletion, *pending.askResult)
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
	} else if pending.ackCompletion != nil && pending.ack != nil {
		deliverBridgeAckResult(pending.ackCompletion, *pending.ack)
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
	} else if pending.sender != nil {
		if pending.intent != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), pending.sender, pending.intent)
		} else if pending.ack != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), pending.sender, pending.ack)
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
	oldDurable := a.durableState()
	a.bridgeSequence++
	delivery := application.BridgeDelivery{Sequence: a.bridgeSequence, SourceAgentID: message.SourceAgentID, TargetAgentID: a.id, RequestID: message.RequestID, DedupeID: message.DedupeID, ChainID: message.ChainID, Deadline: message.Deadline, HopLimit: message.HopLimit - 1, Payload: append([]byte(nil), message.Payload...), Policy: policy, Kind: kind}
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
	key, scope := a.sourceMutationScope(message.SessionID, message.GenerationID, message.Principal, message.Fence)
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
	oldDurable := a.durableState()
	a.bridgeSequence++
	delivery := application.BridgeDelivery{Sequence: a.bridgeSequence, SourceAgentID: message.SourceAgentID, TargetAgentID: a.id, RequestID: message.RequestID, DedupeID: message.DedupeID, ChainID: message.ChainID, Deadline: message.Deadline, HopLimit: message.HopLimit - 1, Kind: kind}
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

func sourceMutationScopeKey(sessionID, generationID, principal string, fence, incarnation uint64) string {
	return fmt.Sprintf("%d:%s%d:%s%d:%s:%d:%d", len(sessionID), sessionID, len(generationID), generationID, len(principal), principal, fence, incarnation)
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
		respondBridgeAck(ctx, message.Completion, &application.BridgeDeliveryAckResult{Reason: "durable persistence is busy"})
		return
	}
	index := slices.IndexFunc(a.bridgeDeliveries, func(item application.BridgeDelivery) bool {
		return item.Sequence == message.Sequence && item.DedupeID == message.DedupeID
	})
	if index < 0 {
		respondBridgeAck(ctx, message.Completion, &application.BridgeDeliveryAckResult{Reason: "delivery is not retained"})
		return
	}
	key := a.deliverySources[message.Sequence]
	scope := a.mutationScopes[key]
	if scope == nil {
		respondBridgeAck(ctx, message.Completion, &application.BridgeDeliveryAckResult{Reason: "delivery source scope is unavailable"})
		return
	}
	record, ok := scope.dedupe[message.DedupeID]
	if !ok || record.sequence != message.Sequence {
		respondBridgeAck(ctx, message.Completion, &application.BridgeDeliveryAckResult{Reason: "delivery acknowledgement identity rejected"})
		return
	}
	deliveryKind := a.bridgeDeliveries[index].Kind
	result := application.BridgeIntentResult{Accepted: true, Completed: message.Delivered, Reason: message.Reason}
	if message.Delivered {
		if deliveryKind == application.BridgeDeliveryPrompt {
			if len(message.Result) == 0 {
				respondBridgeAck(ctx, message.Completion, &application.BridgeDeliveryAckResult{Reason: "prompt completion answer is empty"})
				return
			}
			result.Result = append([]byte(nil), message.Result...)
		} else {
			result.Result = []byte("delivery acknowledged")
		}
	}
	oldDurable := a.durableState()
	a.bridgeDeliveries = append(a.bridgeDeliveries[:index], a.bridgeDeliveries[index+1:]...)
	delete(a.deliverySources, message.Sequence)
	mutation := scope.results[record.mutationSequence]
	mutation.pending, mutation.result = false, result
	scope.results[record.mutationSequence] = mutation
	scope.completed++
	delete(scope.dedupe, message.DedupeID)
	delete(scope.chains, record.chainID)
	retireMutationResults(scope)
	var askCompletion chan<- application.BridgeIntentResult
	if pending, exists := scope.asks[message.DedupeID]; exists {
		askCompletion = pending.completion
		delete(scope.asks, message.DedupeID)
	}
	a.pruneMutationScope(key, scope)
	ack := application.BridgeDeliveryAckResult{Accepted: true}
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{sender: ctx.Sender(), old: oldDurable, ack: &ack, ackCompletion: message.Completion, askScope: key, askDedupe: message.DedupeID, askCompletion: askCompletion, askResult: &result}) {
		return
	}
	if askCompletion != nil {
		deliverBridgeIntentResult(askCompletion, result)
	}
	respondBridgeAck(ctx, message.Completion, &ack)
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
		delete(a.mutationScopes, key)
	}
}
func (a *AgentActor) pruneMutationScope(key string, scope *mutationScope) {
	if len(scope.dedupe) != 0 {
		return
	}
	attachment, active := a.attachments[generationKey(scope.sessionID, scope.generationID)]
	if !active || attachment.principal != scope.principal || attachment.fence != scope.fence || scope.incarnation != a.hostedPiRuntime.Incarnation {
		delete(a.mutationScopes, key)
	}
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
	index := slices.IndexFunc(a.bridgeDeliveries, func(item application.BridgeDelivery) bool {
		return item.Sequence == record.sequence && item.DedupeID == message.DedupeID
	})
	if index >= 0 {
		a.bridgeDeliveries = append(a.bridgeDeliveries[:index], a.bridgeDeliveries[index+1:]...)
	}
	delete(a.deliverySources, record.sequence)
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
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: oldDurable, askScope: message.ScopeKey, askDedupe: message.DedupeID, askCompletion: askCompletion, askResult: &result, retryTimeout: true}) {
		return
	}
	if askCompletion != nil {
		deliverBridgeIntentResult(askCompletion, result)
	}
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
