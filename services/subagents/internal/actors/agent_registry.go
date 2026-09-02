package actors

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
	"github.com/tochemey/goakt/v4/passivation"
	"github.com/tochemey/goakt/v4/supervisor"
)

const (
	maxAgentRegistryRestarts      = 3
	agentRegistryRestartWindow    = time.Second
	maxAgentReconcileSpawnRetries = 20
	agentReconcileSpawnDelay      = 25 * time.Millisecond
)

type pendingRegistration struct {
	request      application.CoordinateAgentRegistration
	compensators []chan<- application.UnregisterAgentResult
	completed    bool
	result       application.RegisterAgentResult
}

type registeredAgent struct {
	actorName               string
	runtimeName             string
	registrationOperationID string
	agentPID, runtimePID    *actor.PID
	reference               application.AgentReference
	allowed                 map[string]struct{}
	recipe                  application.RegisterAgent
	restarts                []time.Time
}

// AgentRegistryActor owns global AgentActors and only mirrors the ephemeral
// grant needed to authorize location-transparent routing.
type AgentRegistryActor struct {
	sessions          map[string]sessionRecord
	agents            map[string]registeredAgent
	registrations     map[string]*pendingRegistration
	compensated       map[string]application.UnregisterAgentResult
	registrationDelay time.Duration
	publicNode        string
	publicAuthority   string
	publicEpoch       uint64
	publicSequence    uint64
	publicResetSent   bool
	clientEpoch       uint64
	clientSequence    uint64
	clientResetSent   bool
}

func NewAgentRegistryActor(registrationDelay ...time.Duration) *AgentRegistryActor {
	value := &AgentRegistryActor{sessions: make(map[string]sessionRecord), agents: make(map[string]registeredAgent), registrations: make(map[string]*pendingRegistration), compensated: make(map[string]application.UnregisterAgentResult)}
	if len(registrationDelay) > 0 {
		value.registrationDelay = registrationDelay[0]
	}
	return value
}
func (*AgentRegistryActor) PreStart(*actor.Context) error { return nil }
func (*AgentRegistryActor) PostStop(*actor.Context) error { return nil }
func (a *AgentRegistryActor) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *actor.PostStart:
		a.clientEpoch = uint64(time.Now().UnixNano())
		if a.clientEpoch == 0 {
			a.clientEpoch = 1
		}
		if topic := ctx.ActorSystem().TopicActor(); topic != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), topic, actor.NewSubscribe(publicAgentDirectoryRequestTopic))
		}
		a.publishClientAgentSnapshot(ctx)
	case *application.StageSession:
		accepted := message.Registry == application.AgentRegistry && a.stage(message.Session)
		a.ack(ctx, message.Acknowledge, &application.SessionStageAck{SessionID: message.Session.SessionID, GenerationID: message.Session.GenerationID, Registry: application.AgentRegistry, Accepted: accepted})
	case *application.PrepareSessionClose:
		a.prepareClose(ctx, message)
	case *application.CommitSessionClose:
		if record, exists := a.sessions[message.SessionID]; exists && record.generationID == message.GenerationID {
			delete(a.sessions, message.SessionID)
		}
		a.ack(ctx, message.Acknowledge, &application.SessionCommitAck{SessionID: message.SessionID, GenerationID: message.GenerationID, Registry: application.AgentRegistry})
	case *application.ConfigurePublicAgentEvents:
		a.publicNode = strings.TrimSpace(message.NodeIdentity)
		a.publicAuthority = strings.TrimSpace(message.PlacementAuthority)
		a.publicEpoch = message.Epoch
		a.publicSequence = 0
		a.publicResetSent = false
		a.publishPublicAgentSnapshot(ctx)
		a.schedulePublicAgentSnapshot(ctx)
	case *application.PublishPublicAgentSnapshot:
		a.publishPublicAgentSnapshot(ctx)
	case *application.PublishPublicAgentSnapshotTick:
		a.publishPublicAgentSnapshot(ctx)
		a.schedulePublicAgentSnapshot(ctx)
	case *application.PublicAgentSnapshotRequest:
		if strings.TrimSpace(message.NodeIdentity) != a.publicNode {
			a.publishPublicAgentSnapshot(ctx)
		}
	case *actor.SubscribeAck:
	case *application.CoordinateAgentRegistration:
		a.coordinateRegistration(ctx, message)
	case *application.CompleteAgentRegistration:
		a.completeRegistration(ctx, message.OperationID)
	case *application.ConfirmAgentRegistration:
		a.confirmRegistration(message.OperationID)
	case *application.CompensateAgentRegistration:
		a.compensateRegistration(ctx, message)
	case *application.AcknowledgeAgentRegistrationTracking:
		delete(a.compensated, message.OperationID)
	case *application.UnregisterAgent:
		a.unregister(ctx, message)
	case *application.ListPublicHostedAgents:
		limit := int(message.Limit)
		if limit <= 0 || limit > 256 {
			limit = 256
		}
		agents := make([]application.PublicHostedAgent, 0, min(len(a.agents), limit))
		for _, item := range a.agents {
			if item.reference.AuthorityBinding.Kind == application.AuthorityBindingHostedOwned && len(agents) < limit {
				agents = append(agents, application.PublicHostedAgent{AgentID: item.reference.AgentID, ActorName: item.actorName, Reference: item.reference})
			}
		}
		slices.SortFunc(agents, func(left, right application.PublicHostedAgent) int { return cmpString(left.AgentID, right.AgentID) })
		ctx.Response(&application.ListPublicHostedAgentsResult{Agents: agents})
	case *application.UpdateAgentMetadata:
		a.updateMetadata(ctx, message)
	case *application.ResolveAgentControl:
		item, exists := a.agents[message.AgentID]
		if !exists {
			ctx.Response(&application.AgentControlPID{})
			return
		}
		pid, err := ctx.ActorSystem().ActorOf(ctx.Context(), item.actorName)
		if err != nil {
			ctx.Response(&application.AgentControlPID{})
			return
		}
		item.agentPID = pid
		a.agents[message.AgentID] = item
		ctx.Response(&application.AgentControlPID{PID: pid, Found: true, Reference: item.reference})
	case *application.RetryAgentReconciliation:
		item, exists := a.agents[message.AgentID]
		if exists && item.agentPID == nil {
			a.reconcileAgentTermination(ctx, message.AgentID, item, message.Attempt)
		}
	case *application.ListAgents:
		if !a.authorized(message.SessionID, message.GenerationID, message.Caller, message.Credential, "observe") {
			ctx.Response(&application.AgentList{})
			return
		}
		agents := make([]application.AgentReference, 0, len(a.agents))
		for _, item := range a.agents {
			agents = append(agents, item.reference)
		}
		slices.SortFunc(agents, func(left, right application.AgentReference) int { return cmpString(left.AgentID, right.AgentID) })
		ctx.Response(&application.AgentList{Agents: agents})
	case *application.ClientAgentRosterSnapshot:
		a.clientRosterSnapshot(ctx, message)
	case *application.ResolveAgent:
		if !a.authorized(message.SessionID, message.GenerationID, message.Caller, message.Credential, "observe") {
			ctx.Response(&application.ResolveAgentResult{})
			return
		}
		if agent, ok := a.agents[message.AgentID]; ok {
			ctx.Response(&application.ResolveAgentResult{Found: true, Agent: agent.reference})
			return
		}
		candidates := make([]application.AgentReference, 0)
		for id, item := range a.agents {
			if strings.HasPrefix(id, message.AgentID) {
				candidates = append(candidates, item.reference)
			}
		}
		slices.SortFunc(candidates, func(left, right application.AgentReference) int { return cmpString(left.AgentID, right.AgentID) })
		if len(candidates) == 1 {
			ctx.Response(&application.ResolveAgentResult{Found: true, Agent: candidates[0]})
		} else {
			ctx.Response(&application.ResolveAgentResult{Ambiguous: len(candidates) > 1, Candidates: candidates})
		}
	case *application.AuthorizeAgentAccess:
		a.authorizeRoute(ctx, message)
	case *application.HostedPiRuntimeStateChanged:
		if item, ok := a.agents[message.AgentID]; ok && item.reference.AuthorityBinding.Kind == application.AuthorityBindingHostedOwned && item.reference.AuthorityBinding.HostedRuntimeID == message.Binding.RuntimeID && validRuntimeProjectionAdvance(item.reference.HostedPiRuntime, message.Binding) {
			item.reference.HostedPiRuntime = message.Binding
			item.recipe.HostedPiRuntime = message.Binding
			item.recipe.LaunchSpec.Incarnation = message.Binding.Incarnation
			if item.recipe.DurableRecord != nil {
				item.recipe.DurableRecord.Binding = message.Binding
				item.recipe.DurableRecord.LaunchSpec.Incarnation = message.Binding.Incarnation
			}
			item.reference.LifecycleRevision++
			a.agents[message.AgentID] = item
			a.publishClientAgentUpsert(ctx, message.AgentID, item)
			a.publishPublicAgentUpsert(ctx, message.AgentID, item)
		}
	case *actor.Terminated:
		name := message.ActorPath().Name()
		for id, item := range a.agents {
			switch name {
			case item.actorName:
				a.reconcileAgentTermination(ctx, id, item, 0)
			case item.runtimeName:
				item.runtimePID = nil
				item.reference.HostedPiRuntime.State = application.HostedPiRuntimeDegraded
				item.reference.HostedPiRuntime.BridgeReady = false
				item.reference.LifecycleRevision++
				a.agents[id] = item
				a.publishClientAgentUpsert(ctx, id, item)
				a.publishPublicAgentUpsert(ctx, id, item)
			}
		}
	default:
		ctx.Unhandled()
	}
}

func (a *AgentRegistryActor) stage(message application.OpenSession) bool {
	if !validSession(message) {
		return false
	}
	if current, exists := a.sessions[message.SessionID]; exists {
		return sameSessionRecord(current, message)
	}
	capabilities := make(map[string]struct{}, len(message.Capabilities))
	for _, capability := range message.Capabilities {
		capabilities[capability] = struct{}{}
	}
	if strings.HasPrefix(message.Caller, "hosted:") {
		if _, ok := capabilities["hosted_bridge"]; ok {
			capabilities["activity_write"] = struct{}{}
		}
	}
	a.sessions[message.SessionID] = sessionRecord{generationID: message.GenerationID, caller: message.Caller, credential: append([]byte(nil), message.Credential...), capabilities: capabilities, expiresAt: message.ExpiresAt, persistent: message.Persistent}
	return true
}

func (a *AgentRegistryActor) coordinateRegistration(ctx *actor.ReceiveContext, message *application.CoordinateAgentRegistration) {
	if message == nil || message.OperationID == "" {
		return
	}
	if current := a.registrations[message.OperationID]; current != nil {
		if current.completed {
			deliverRegisterResult(message.Result, current.result)
		} else {
			current.request.Result = message.Result
		}
		return
	}
	copy := *message
	a.registrations[message.OperationID] = &pendingRegistration{request: copy}
	if a.registrationDelay > 0 {
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &application.CompleteAgentRegistration{OperationID: message.OperationID}, ctx.Self(), a.registrationDelay)
		return
	}
	a.completeRegistration(ctx, message.OperationID)
}

func (a *AgentRegistryActor) confirmRegistration(operationID string) {
	pending := a.registrations[operationID]
	if pending != nil {
		agentID := pending.request.Registration.AgentID
		if item, exists := a.agents[agentID]; exists && item.registrationOperationID == operationID {
			item.registrationOperationID = ""
			a.agents[agentID] = item
		}
	}
	delete(a.registrations, operationID)
}

func (a *AgentRegistryActor) completeRegistration(ctx *actor.ReceiveContext, operationID string) {
	pending := a.registrations[operationID]
	if pending == nil {
		return
	}
	result := a.register(ctx, &pending.request.Registration, operationID)
	pending.completed, pending.result = true, result
	deliverRegisterResult(pending.request.Result, result)
	if len(pending.compensators) == 0 {
		return
	}
	delete(a.registrations, operationID)
	a.beginRegistrationCompensation(ctx, operationID, pending.request.Registration.AgentID, result, pending.compensators)
}

func (a *AgentRegistryActor) beginRegistrationCompensation(ctx *actor.ReceiveContext, operationID, agentID string, result application.RegisterAgentResult, requesters []chan<- application.UnregisterAgentResult) {
	if !result.Created {
		outcome := application.UnregisterAgentResult{Completed: true}
		a.compensated[operationID] = outcome
		for _, requester := range requesters {
			deliverUnregisterResult(requester, outcome)
		}
		return
	}
	item, exists := a.agents[agentID]
	if !exists || item.registrationOperationID != operationID {
		for _, requester := range requesters {
			deliverUnregisterResult(requester, application.UnregisterAgentResult{Reason: "created registration PID is no longer exactly registered"})
		}
		return
	}
	if result.AgentPID != nil {
		ctx.UnWatch(result.AgentPID)
	}
	if item.runtimePID != nil {
		ctx.UnWatch(item.runtimePID)
	}
	delete(a.agents, agentID)
	a.publishClientAgentRemove(ctx, agentID, item)
	a.publishPublicAgentRemove(ctx, agentID, item)
	// Registry retirement and exact PID publication are immediate. Service-owned
	// asynchronous cleanup may take arbitrarily longer without losing identity.
	outcome := application.UnregisterAgentResult{Completed: true, RuntimePID: result.RuntimePID, AgentPID: result.AgentPID}
	a.compensated[operationID] = outcome
	for _, requester := range requesters {
		deliverUnregisterResult(requester, outcome)
	}
}

func (a *AgentRegistryActor) compensateRegistration(ctx *actor.ReceiveContext, message *application.CompensateAgentRegistration) {
	if message == nil {
		return
	}
	if outcome, exists := a.compensated[message.OperationID]; exists {
		deliverUnregisterResult(message.Result, outcome)
		return
	}
	if pending := a.registrations[message.OperationID]; pending != nil {
		if pending.request.Registration.AgentID != message.AgentID {
			deliverUnregisterResult(message.Result, application.UnregisterAgentResult{Reason: "registration compensation identity mismatch"})
			return
		}
		pending.compensators = append(pending.compensators, message.Result)
		if pending.completed {
			delete(a.registrations, message.OperationID)
			a.beginRegistrationCompensation(ctx, message.OperationID, message.AgentID, pending.result, pending.compensators)
		}
		return
	}
	if item, exists := a.agents[message.AgentID]; exists && item.registrationOperationID == message.OperationID {
		a.beginRegistrationCompensation(ctx, message.OperationID, message.AgentID, application.RegisterAgentResult{Created: true, AgentPID: item.agentPID, RuntimePID: item.runtimePID}, []chan<- application.UnregisterAgentResult{message.Result})
		return
	}
	deliverUnregisterResult(message.Result, application.UnregisterAgentResult{Reason: "registration compensation operation is no longer provable"})
}

func (a *AgentRegistryActor) register(ctx *actor.ReceiveContext, message *application.RegisterAgent, operationID string) application.RegisterAgentResult {
	if !validRegistration(message) {
		return application.RegisterAgentResult{Reason: "invalid agent registration"}
	}
	if _, exists := a.agents[message.AgentID]; exists {
		return application.RegisterAgentResult{Reason: "agent already registered"}
	}
	// Actor names must be deterministic per logical agent id so refs recorded in
	// durable outbox/correlation state survive re-registration; random per-
	// registration names orphaned every retained ref after a wipe or re-create.
	name := stableAgentActorName(message.AgentID)
	pid, spawnErr := ctx.ActorSystem().Spawn(context.WithoutCancel(ctx.Context()), name, NewAgentActor(message, ctx.Self()), actor.WithMailbox(actor.NewNonBlockingBoundedMailbox(1024)), actor.WithPassivationStrategy(passivation.NewLongLivedStrategy()), actor.WithSupervisor(supervisor.NewSupervisor(supervisor.WithAnyErrorDirective(supervisor.RestartDirective))))
	if spawnErr != nil || pid == nil {
		return application.RegisterAgentResult{Reason: "agent actor spawn failed"}
	}
	ctx.Watch(pid)
	if message.DurableRecord != nil {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), pid, &restoreDurableTimers{})
	}
	allowed := make(map[string]struct{}, len(message.AllowedCapability))
	for _, capability := range message.AllowedCapability {
		allowed[capability] = struct{}{}
	}
	recipe := copyRegistrationRecipe(message)
	role := aggregateRole(message.AgentID, message.Role)
	displayName := aggregateDisplayName(message.AgentID, message.DisplayName)
	a.agents[message.AgentID] = registeredAgent{actorName: name, registrationOperationID: operationID, agentPID: pid, reference: application.AgentReference{AgentID: message.AgentID, LifecycleRevision: 1, Role: role, DisplayName: displayName, RetentionPolicy: message.Retention, RecoveryPolicy: message.Recovery, AuthorityBinding: message.AuthorityBinding, HostedPiRuntime: message.HostedPiRuntime}, allowed: allowed, recipe: recipe}
	defer func() {
		if item, exists := a.agents[message.AgentID]; exists {
			a.publishClientAgentUpsert(ctx, message.AgentID, item)
			a.publishPublicAgentUpsert(ctx, message.AgentID, item)
		}
	}()
	var hostedRuntimePID *actor.PID
	if message.PhaseTwoOwned {
		runtimeName := hostedRuntimeActorName(message)
		runtimePID, err := ctx.ActorSystem().ActorOf(ctx.Context(), runtimeName)
		if err != nil {
			runtimePID = ctx.Spawn(runtimeName, NewHostedPiRuntimeActor(message.Runtime, message.LaunchSpec, pid, message.AdoptedProcess), actor.WithMailbox(actor.NewNonBlockingBoundedMailbox(64)), actor.WithPassivationStrategy(passivation.NewLongLivedStrategy()), actor.WithSupervisor(supervisor.NewSupervisor(supervisor.WithAnyErrorDirective(supervisor.RestartDirective))))
		}
		if runtimePID == nil {
			delete(a.agents, message.AgentID)
			go pid.Shutdown(context.Background())
			return application.RegisterAgentResult{Reason: "hosted runtime actor spawn failed"}
		}
		hostedRuntimePID = runtimePID
		ctx.Watch(runtimePID)
		item := a.agents[message.AgentID]
		item.runtimeName, item.runtimePID = runtimeName, runtimePID
		a.agents[message.AgentID] = item
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), pid, &application.BindHostedPiRuntimeActor{PID: runtimePID})
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), runtimePID, &application.RebindHostedPiRuntimeOwner{PID: pid})
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), runtimePID, &application.StartHostedPiRuntime{Timeout: message.RuntimeStartTimeout})
	}
	return application.RegisterAgentResult{Created: true, RuntimePID: hostedRuntimePID, AgentPID: pid}
}

func (a *AgentRegistryActor) reconcileAgentTermination(ctx *actor.ReceiveContext, agentID string, item registeredAgent, attempt uint8) {
	now := time.Now()
	window := item.restarts[:0]
	for _, previous := range item.restarts {
		if now.Sub(previous) <= agentRegistryRestartWindow {
			window = append(window, previous)
		}
	}
	if len(window) >= maxAgentRegistryRestarts || item.recipe.AgentID == "" {
		item.agentPID = nil
		item.runtimePID = nil
		item.reference.LifecycleRevision++
		a.agents[agentID] = item
		a.publishPublicAgentUpsert(ctx, agentID, item)
		return
	}
	actorRecipe := copyRegistrationRecipe(&item.recipe)
	pid, spawnErr := ctx.ActorSystem().Spawn(context.WithoutCancel(ctx.Context()), item.actorName, NewAgentActor(&actorRecipe, ctx.Self()), actor.WithMailbox(actor.NewNonBlockingBoundedMailbox(1024)), actor.WithPassivationStrategy(passivation.NewLongLivedStrategy()), actor.WithSupervisor(supervisor.NewSupervisor(supervisor.WithAnyErrorDirective(supervisor.RestartDirective))))
	if spawnErr != nil || pid == nil {
		item.agentPID = nil
		a.agents[agentID] = item
		if int(attempt) < maxAgentReconcileSpawnRetries {
			_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &application.RetryAgentReconciliation{AgentID: agentID, Attempt: attempt + 1}, ctx.Self(), agentReconcileSpawnDelay)
			return
		}
		item.runtimePID = nil
		item.reference.LifecycleRevision++
		a.agents[agentID] = item
		a.publishPublicAgentUpsert(ctx, agentID, item)
		return
	}
	item.restarts = append(window, now)
	ctx.Watch(pid)
	item.agentPID = pid
	if item.recipe.DurableRecord != nil {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), pid, &restoreDurableTimers{})
	}
	if item.recipe.PhaseTwoOwned && item.runtimeName != "" {
		runtimePID, err := ctx.ActorSystem().ActorOf(ctx.Context(), item.runtimeName)
		if err != nil {
			runtimePID = ctx.Spawn(item.runtimeName, NewHostedPiRuntimeActor(item.recipe.Runtime, item.recipe.LaunchSpec, pid, item.recipe.AdoptedProcess), actor.WithMailbox(actor.NewNonBlockingBoundedMailbox(64)), actor.WithPassivationStrategy(passivation.NewLongLivedStrategy()), actor.WithSupervisor(supervisor.NewSupervisor(supervisor.WithAnyErrorDirective(supervisor.RestartDirective))))
		}
		if runtimePID != nil {
			ctx.Watch(runtimePID)
			item.runtimePID = runtimePID
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), pid, &application.BindHostedPiRuntimeActor{PID: runtimePID})
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), runtimePID, &application.RebindHostedPiRuntimeOwner{PID: pid})
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), runtimePID, &application.StartHostedPiRuntime{Timeout: item.recipe.RuntimeStartTimeout})
		}
	}
	item.reference.LifecycleRevision++
	a.agents[agentID] = item
	a.publishPublicAgentUpsert(ctx, agentID, item)
}

func (a *AgentRegistryActor) clientRosterSnapshot(ctx *actor.ReceiveContext, message *application.ClientAgentRosterSnapshot) {
	if !a.authorized(message.SessionID, message.GenerationID, message.Caller, message.Credential, "observe") {
		ctx.Response(&application.ClientAgentRosterSnapshotResult{Reason: "session authorization denied"})
		return
	}
	events := make([]application.ClientAgentRosterEvent, 0, len(a.agents)+1)
	sequence := a.clientSequence + 1
	events = append(events, application.ClientAgentRosterEvent{Operation: application.ClientAgentRosterSnapshotReset, Epoch: a.clientEpoch, Sequence: sequence})
	agents := make([]registeredAgent, 0, len(a.agents))
	for _, item := range a.agents {
		agents = append(agents, item)
	}
	slices.SortFunc(agents, func(left, right registeredAgent) int {
		return cmpString(left.reference.AgentID, right.reference.AgentID)
	})
	for _, item := range agents {
		sequence++
		events = append(events, application.ClientAgentRosterEvent{Operation: application.ClientAgentRosterUpsert, Epoch: a.clientEpoch, Sequence: sequence, AgentID: item.reference.AgentID, Reference: item.reference, Status: clientAgentStatus(item.reference)})
	}
	a.clientSequence = sequence
	ctx.Response(&application.ClientAgentRosterSnapshotResult{Events: events})
}

func (a *AgentRegistryActor) publishClientAgentSnapshot(ctx *actor.ReceiveContext) {
	if !a.clientResetSent {
		a.publishClientAgentEvent(ctx, &application.ClientAgentRosterEvent{Operation: application.ClientAgentRosterSnapshotReset})
		a.clientResetSent = true
	}
	for agentID, item := range a.agents {
		a.publishClientAgentUpsert(ctx, agentID, item)
	}
}

func (a *AgentRegistryActor) publishClientAgentUpsert(ctx *actor.ReceiveContext, agentID string, item registeredAgent) {
	a.publishClientAgentEvent(ctx, &application.ClientAgentRosterEvent{Operation: application.ClientAgentRosterUpsert, AgentID: agentID, Reference: item.reference, Status: clientAgentStatus(item.reference)})
}

func (a *AgentRegistryActor) publishClientAgentRemove(ctx *actor.ReceiveContext, agentID string, item registeredAgent) {
	reference := item.reference
	reference.LifecycleRevision++
	a.publishClientAgentEvent(ctx, &application.ClientAgentRosterEvent{Operation: application.ClientAgentRosterRemove, AgentID: agentID, Reference: reference, Status: "removed"})
}

func (a *AgentRegistryActor) publishClientAgentEvent(ctx *actor.ReceiveContext, event *application.ClientAgentRosterEvent) {
	if topic := ctx.ActorSystem().TopicActor(); topic != nil {
		a.clientSequence++
		event.Epoch = a.clientEpoch
		event.Sequence = a.clientSequence
		id := "client-roster:" + event.AgentID + ":" + strconv.FormatUint(event.Epoch, 10) + ":" + strconv.FormatUint(event.Sequence, 10)
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), topic, actor.NewPublish(id, application.ClientAgentRosterTopic, event))
	}
}

func clientAgentStatus(reference application.AgentReference) string {
	if reference.HostedPiRuntime.State == application.HostedPiRuntimeReady && reference.HostedPiRuntime.BridgeReady {
		return "ready"
	}
	switch reference.HostedPiRuntime.State {
	case application.HostedPiRuntimeStarting:
		return "starting"
	case application.HostedPiRuntimeReady:
		return "ready"
	case application.HostedPiRuntimeDegraded:
		return "degraded"
	case application.HostedPiRuntimeStopping:
		return "stopping"
	case application.HostedPiRuntimeStopped:
		return "stopped"
	}
	if reference.AuthorityBinding.Kind == application.AuthorityBindingPhaseOneObservedUpstream {
		return "observed"
	}
	return "registered"
}

func (a *AgentRegistryActor) publishPublicAgentSnapshot(ctx *actor.ReceiveContext) {
	if a.publicNode == "" {
		return
	}
	if !a.publicResetSent {
		a.publishPublicAgentEvent(ctx, &application.PublicAgentDirectoryEvent{Operation: "snapshot-reset", NodeIdentity: a.publicNode})
		a.publicResetSent = true
	}
	for agentID, item := range a.agents {
		a.publishPublicAgentUpsert(ctx, agentID, item)
	}
}

func (a *AgentRegistryActor) schedulePublicAgentSnapshot(ctx *actor.ReceiveContext) {
	if a.publicNode != "" {
		_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &application.PublishPublicAgentSnapshotTick{}, ctx.Self(), time.Second)
	}
}

func (a *AgentRegistryActor) publishPublicAgentUpsert(ctx *actor.ReceiveContext, agentID string, item registeredAgent) {
	if a.publicNode == "" || item.reference.AuthorityBinding.Kind != application.AuthorityBindingHostedOwned {
		return
	}
	if a.publicAuthority == "" {
		return
	}
	a.publishPublicAgentEvent(ctx, &application.PublicAgentDirectoryEvent{Operation: "upsert", NodeIdentity: a.publicNode, AgentID: agentID, ActorName: a.publicAuthority, Reference: item.reference})
}

func (a *AgentRegistryActor) publishPublicAgentRemove(ctx *actor.ReceiveContext, agentID string, item registeredAgent) {
	if a.publicNode == "" {
		return
	}
	reference := item.reference
	reference.LifecycleRevision++
	a.publishPublicAgentEvent(ctx, &application.PublicAgentDirectoryEvent{Operation: "remove", NodeIdentity: a.publicNode, AgentID: agentID, Reference: reference})
}

func (a *AgentRegistryActor) publishPublicAgentEvent(ctx *actor.ReceiveContext, event *application.PublicAgentDirectoryEvent) {
	if topic := ctx.ActorSystem().TopicActor(); topic != nil {
		a.publicSequence++
		event.Epoch = a.publicEpoch
		event.Sequence = a.publicSequence
		id := event.NodeIdentity + ":" + event.AgentID + ":" + strconv.FormatUint(event.Epoch, 10) + ":" + strconv.FormatUint(event.Sequence, 10)
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), topic, actor.NewPublish(id, publicAgentDirectoryTopic, event))
	}
}

func validRuntimeProjectionAdvance(current, next application.HostedPiRuntimeBinding) bool {
	if next.Incarnation != current.Incarnation {
		return current.State == application.HostedPiRuntimeDegraded && next.State == application.HostedPiRuntimeStarting && next.Incarnation == current.Incarnation+1
	}
	if next.State == current.State {
		return next.State != application.HostedPiRuntimeUnspecified
	}
	switch current.State {
	case application.HostedPiRuntimeInactive:
		return next.State == application.HostedPiRuntimeStarting || next.State == application.HostedPiRuntimeDegraded || next.State == application.HostedPiRuntimeStopped
	case application.HostedPiRuntimeStarting:
		return next.State == application.HostedPiRuntimeReady || next.State == application.HostedPiRuntimeDegraded || next.State == application.HostedPiRuntimeStopping || next.State == application.HostedPiRuntimeStopped
	case application.HostedPiRuntimeReady:
		return next.State == application.HostedPiRuntimeDegraded || next.State == application.HostedPiRuntimeStopping || next.State == application.HostedPiRuntimeStopped
	case application.HostedPiRuntimeDegraded:
		return next.State == application.HostedPiRuntimeStopping || next.State == application.HostedPiRuntimeStopped
	case application.HostedPiRuntimeStopping:
		return next.State == application.HostedPiRuntimeDegraded || next.State == application.HostedPiRuntimeStopped
	default:
		return false
	}
}

// hostedRuntimeActorName is lifecycle-internal and runtime-registration-scoped. Durable
// task/credit/completion routing addresses stableAgentActorName(agentID); it
// must never retain or resolve this child name as the communication endpoint.
func hostedRuntimeActorName(message *application.RegisterAgent) string {
	digest := sha256.Sum256([]byte(message.AgentID + "\x00" + message.HostedPiRuntime.RuntimeID + "\x00" + message.LaunchSpec.PiSessionName))
	return hostedRuntimeActorPrefix + hex.EncodeToString(digest[:8])
}

func copyRegistrationRecipe(message *application.RegisterAgent) application.RegisterAgent {
	copy := *message
	copy.AllowedCapability = append([]string(nil), message.AllowedCapability...)
	if message.DurableRecord != nil {
		record := *message.DurableRecord
		record.AllowedCapabilities = append([]string(nil), message.DurableRecord.AllowedCapabilities...)
		record.Session.Capabilities = append([]string(nil), message.DurableRecord.Session.Capabilities...)
		copy.DurableRecord = &record
	}
	return copy
}

func deliverRegisterResult(target chan<- application.RegisterAgentResult, result application.RegisterAgentResult) {
	if target == nil {
		return
	}
	select {
	case target <- result:
	default:
	}
}

func (a *AgentRegistryActor) unregister(ctx *actor.ReceiveContext, message *application.UnregisterAgent) {
	item, exists := a.agents[message.AgentID]
	if !exists {
		deliverUnregisterResult(message.Result, application.UnregisterAgentResult{Completed: true})
		return
	}
	pid, err := ctx.ActorSystem().ActorOf(ctx.Context(), item.actorName)
	if err != nil {
		delete(a.agents, message.AgentID)
		a.publishClientAgentRemove(ctx, message.AgentID, item)
		a.publishPublicAgentRemove(ctx, message.AgentID, item)
		deliverUnregisterResult(message.Result, application.UnregisterAgentResult{Completed: true})
		return
	}
	ctx.UnWatch(pid)
	if item.runtimePID != nil {
		ctx.UnWatch(item.runtimePID)
	}
	delete(a.agents, message.AgentID)
	a.publishClientAgentRemove(ctx, message.AgentID, item)
	a.publishPublicAgentRemove(ctx, message.AgentID, item)
	result, runtimePID := message.Result, item.runtimePID
	go func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		err := pid.Shutdown(shutdownCtx)
		if runtimePID != nil {
			if runtimeErr := runtimePID.Shutdown(shutdownCtx); err == nil {
				err = runtimeErr
			}
		}
		response := application.UnregisterAgentResult{Completed: err == nil, RuntimePID: runtimePID, AgentPID: pid}
		if err != nil {
			response.Reason = err.Error()
		}
		deliverUnregisterResult(result, response)
	}()
}

func deliverUnregisterResult(target chan<- application.UnregisterAgentResult, result application.UnregisterAgentResult) {
	if target == nil {
		return
	}
	select {
	case target <- result:
	default:
	}
}

func (a *AgentRegistryActor) authorizeRoute(ctx *actor.ReceiveContext, message *application.AuthorizeAgentAccess) {
	agent, ok := a.agents[message.AgentID]
	if !ok || !a.authorizedAll(message.SessionID, message.GenerationID, message.Caller, message.Credential, message.Capabilities) {
		ctx.Response(&application.AgentRoute{Reason: "agent or session authorization denied"})
		return
	}
	pid, err := ctx.ActorSystem().ActorOf(ctx.Context(), agent.actorName)
	if err != nil {
		ctx.Response(&application.AgentRoute{Reason: "agent unavailable"})
		return
	}
	record := a.sessions[message.SessionID]
	ctx.Response(&application.AgentRoute{Allowed: true, PID: pid, GenerationID: record.generationID, Principal: record.caller})
}

func (a *AgentRegistryActor) prepareClose(ctx *actor.ReceiveContext, message *application.PrepareSessionClose) {
	if record, exists := a.sessions[message.SessionID]; exists && record.generationID == message.GenerationID {
		record.closing = true
		a.sessions[message.SessionID] = record
	}
	names := make([]string, 0, len(a.agents))
	for _, item := range a.agents {
		names = append(names, item.actorName)
	}
	slices.Sort(names)
	a.ack(ctx, message.Acknowledge, &application.SessionPrepareAck{SessionID: message.SessionID, GenerationID: message.GenerationID, Registry: application.AgentRegistry, AgentNames: names})
}

func (*AgentRegistryActor) ack(ctx *actor.ReceiveContext, target *actor.PID, message any) {
	if target != nil {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), target, message)
	}
}
func validRegistration(message *application.RegisterAgent) bool {
	if message == nil || message.AgentID == "" || message.Retention == "" || message.Recovery == "" {
		return false
	}
	binding, hosted := message.AuthorityBinding, message.HostedPiRuntime
	if !message.PhaseTwoOwned {
		metadataNeutral := hosted
		metadataNeutral.DisplayName = ""
		metadataNeutral.Role = ""
		return binding.Kind == application.AuthorityBindingPhaseOneObservedUpstream && binding.ObservedUpstreamRunID != "" && metadataNeutral == application.InactiveHostedPiRuntimeBinding() && message.Runtime == nil
	}
	return binding.Kind == application.AuthorityBindingHostedOwned && binding.HostedRuntimeID != "" && binding.HostedRuntimeID == hosted.RuntimeID && hosted.State == application.HostedPiRuntimeStarting && hosted.Lifetime == application.HostedPiLifetimeGlobalAgent && hosted.TmuxOwnership == application.HostedPiTmuxOwnershipExactSession && hosted.ControlBoundary == application.HostedPiControlDocumentedBridgeOnly && hosted.VisualizationBoundary == application.HostedPiVisualizationTmuxAttach && hosted.Incarnation > 0 && message.Runtime != nil && message.LaunchSpec.AgentID == message.AgentID && message.LaunchSpec.RuntimeID == hosted.RuntimeID && message.LaunchSpec.Incarnation == hosted.Incarnation
}
func (a *AgentRegistryActor) updateMetadata(ctx *actor.ReceiveContext, message *application.UpdateAgentMetadata) {
	if message == nil || message.AgentID == "" {
		deliverRegistryOperationResult(message.Result, application.OperationResult{Reason: "agent metadata identity is invalid"})
		return
	}
	item, exists := a.agents[message.AgentID]
	if !exists {
		deliverRegistryOperationResult(message.Result, application.OperationResult{Reason: "agent not found"})
		return
	}
	displayName := aggregateDisplayName(message.AgentID, message.DisplayName)
	role := aggregateRole(message.AgentID, message.Role)
	if item.reference.DisplayName == displayName && item.reference.Role == role {
		deliverRegistryOperationResult(message.Result, application.OperationResult{Completed: true, Revision: item.reference.LifecycleRevision})
		return
	}
	item.reference.DisplayName = displayName
	item.reference.Role = role
	item.reference.LifecycleRevision++
	item.recipe.DisplayName = displayName
	item.recipe.Role = role
	item.recipe.HostedPiRuntime.DisplayName = displayName
	item.recipe.HostedPiRuntime.Role = role
	if item.recipe.DurableRecord != nil {
		item.recipe.DurableRecord.Binding.DisplayName = displayName
		item.recipe.DurableRecord.Binding.Role = role
	}
	a.agents[message.AgentID] = item
	a.publishClientAgentUpsert(ctx, message.AgentID, item)
	a.publishPublicAgentUpsert(ctx, message.AgentID, item)
	deliverRegistryOperationResult(message.Result, application.OperationResult{Completed: true, Revision: item.reference.LifecycleRevision})
}

func deliverRegistryOperationResult(target chan<- application.OperationResult, result application.OperationResult) {
	if target == nil {
		return
	}
	select {
	case target <- result:
	default:
	}
}

func aggregateRole(agentID, requested string) string {
	if value := boundedDisplayMetadata(requested, 64); value != "" {
		return value
	}
	return ""
}

func aggregateDisplayName(agentID, requested string) string {
	if value := boundedDisplayMetadata(requested, 80); value != "" {
		return value
	}
	return boundedDisplayMetadata(agentID, 80)
}

func boundedDisplayMetadata(value string, limit int) string {
	value = strings.Map(func(r rune) rune {
		switch r {
		case '\x00', '\r', '\n', '\t':
			return -1
		default:
			return r
		}
	}, strings.TrimSpace(value))
	if len(value) > limit {
		value = value[:limit]
	}
	return value
}

func (a *AgentRegistryActor) authorizedAll(sessionID, generationID, caller string, credential []byte, capabilities []string) bool {
	if len(capabilities) == 0 {
		return false
	}
	for _, capability := range capabilities {
		if !a.authorized(sessionID, generationID, caller, credential, capability) {
			return false
		}
	}
	return true
}
func (a *AgentRegistryActor) authorized(sessionID, generationID, caller string, credential []byte, capability string) bool {
	record, ok := a.sessions[sessionID]
	if !ok || record.closing || generationID == "" || record.generationID != generationID || record.caller != caller || (!record.persistent && !record.expiresAt.After(time.Now())) || len(record.credential) != len(credential) || subtle.ConstantTimeCompare(record.credential, credential) != 1 {
		return false
	}
	_, ok = record.capabilities[capability]
	return ok
}
func cmpString(left, right string) int {
	if left < right {
		return -1
	}
	if left > right {
		return 1
	}
	return 0
}
