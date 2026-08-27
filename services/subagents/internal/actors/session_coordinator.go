package actors

import (
	"context"
	"slices"
	"strings"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

const (
	maxSessionIdentities   = 4096
	coordinationRetry      = 10 * time.Millisecond
	maxCoordinationRetries = 8
	maxCoordinationBackoff = 25 * time.Millisecond
)

type sessionPhase uint8

const (
	opening sessionPhase = iota
	active
	closing
	compensating
)

type sessionPlan struct {
	session         application.OpenSession
	phase           sessionPhase
	openRequesters  []chan<- application.CoordinationResult
	closeRequesters []chan<- application.CoordinationResult
	openAcks        map[application.RegistryKind]bool
	prepareAcks     map[application.RegistryKind]bool
	commitAcks      map[application.RegistryKind]bool
	agents          map[string]*actor.PID
	dropped         map[string]bool
	closeRequested  bool
	retryScheduled  bool
	retryAttempts   int
}

// SessionCoordinator owns the idempotent open/close/expiry state machine. Plans
// remain present until both registries and every affected AgentActor acknowledge.
type SessionCoordinator struct {
	sessionRegistry     *actor.PID
	agentRegistry       *actor.PID
	plans               map[string]*sessionPlan
	usedSessions        map[string]struct{}
	usedGenerations     map[string]struct{}
	usedSessionOrder    []string
	usedGenerationOrder []string
}

func NewSessionCoordinator(sessionRegistry, agentRegistry *actor.PID) *SessionCoordinator {
	return &SessionCoordinator{
		sessionRegistry: sessionRegistry,
		agentRegistry:   agentRegistry,
		plans:           make(map[string]*sessionPlan), usedSessions: make(map[string]struct{}), usedGenerations: make(map[string]struct{}),
	}
}
func (*SessionCoordinator) PreStart(*actor.Context) error { return nil }
func (*SessionCoordinator) PostStop(*actor.Context) error { return nil }

func (c *SessionCoordinator) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *application.CoordinateOpen:
		c.beginOpen(ctx, &message.Session, message.Result)
	case *application.SessionStageAck:
		c.stageAck(ctx, message)
	case *application.CoordinateClose:
		c.beginClose(ctx, message.SessionID, message.GenerationID, message.Result)
	case *application.CloseSession:
		c.beginClose(ctx, message.SessionID, message.GenerationID, nil)
	case *application.SessionPrepareAck:
		c.prepareAck(ctx, message)
	case *application.SessionDropped:
		c.dropAck(ctx, message)
	case *application.SessionCommitAck:
		c.commitAck(ctx, message)
	case *application.RetryCoordination:
		c.retry(ctx, message.SessionID, message.GenerationID)
	case *actor.Terminated:
		c.terminated(ctx, message)
	default:
		ctx.Unhandled()
	}
}

func (c *SessionCoordinator) beginOpen(ctx *actor.ReceiveContext, message *application.OpenSession, requester chan<- application.CoordinationResult) {
	if plan := c.plans[message.SessionID]; plan != nil {
		if sameSession(plan.session, *message) && (plan.phase == opening || plan.phase == active) {
			if plan.phase == active {
				deliverCoordinationResult(requester, application.CoordinationResult{Allowed: true})
			} else {
				plan.openRequesters = append(plan.openRequesters, requester)
			}
			return
		}
		deliverCoordinationResult(requester, application.CoordinationResult{Reason: "session identity already used"})
		return
	}
	if _, used := c.usedSessions[message.SessionID]; used || message.SessionID == "" || message.GenerationID == "" {
		deliverCoordinationResult(requester, application.CoordinationResult{Reason: "session identity already used"})
		return
	}
	if _, used := c.usedGenerations[message.GenerationID]; used {
		deliverCoordinationResult(requester, application.CoordinationResult{Reason: "generation identity already used"})
		return
	}
	c.compactIdentityLedgers()
	if len(c.usedSessions) >= maxSessionIdentities || len(c.usedGenerations) >= maxSessionIdentities {
		deliverCoordinationResult(requester, application.CoordinationResult{Reason: "session identity ledger full"})
		return
	}
	c.usedSessions[message.SessionID] = struct{}{}
	c.usedGenerations[message.GenerationID] = struct{}{}
	c.usedSessionOrder = append(c.usedSessionOrder, message.SessionID)
	c.usedGenerationOrder = append(c.usedGenerationOrder, message.GenerationID)
	plan := &sessionPlan{session: cloneSession(*message), phase: opening, openRequesters: []chan<- application.CoordinationResult{requester}, openAcks: make(map[application.RegistryKind]bool), prepareAcks: make(map[application.RegistryKind]bool), commitAcks: make(map[application.RegistryKind]bool)}
	c.plans[message.SessionID] = plan
	c.sendOpen(ctx, plan)
}

func (c *SessionCoordinator) stageAck(ctx *actor.ReceiveContext, message *application.SessionStageAck) {
	plan := c.match(message.SessionID, message.GenerationID)
	if plan == nil || plan.phase != opening {
		return
	}
	if !message.Accepted {
		plan.phase = compensating
		plan.commitAcks = make(map[application.RegistryKind]bool)
		c.sendCommits(ctx, plan)
		return
	}
	plan.openAcks[message.Registry] = true
	if len(plan.openAcks) != 2 {
		return
	}
	plan.phase = active
	if !plan.session.Persistent {
		if err := ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &application.CloseSession{SessionID: plan.session.SessionID, GenerationID: plan.session.GenerationID}, ctx.Self(), time.Until(plan.session.ExpiresAt)); err != nil {
			plan.phase = compensating
			c.sendCommits(ctx, plan)
			return
		}
	}
	c.respondOpen(plan, application.CoordinationResult{Allowed: true})
	if plan.closeRequested {
		c.startClose(ctx, plan)
	}
}

func (c *SessionCoordinator) beginClose(ctx *actor.ReceiveContext, sessionID, generationID string, requester chan<- application.CoordinationResult) {
	plan := c.plans[sessionID]
	if plan == nil || (generationID != "" && plan.session.GenerationID != generationID) {
		if requester != nil {
			deliverCoordinationResult(requester, application.CoordinationResult{Reason: "session generation not found"})
		}
		return
	}
	if requester != nil {
		plan.closeRequesters = append(plan.closeRequesters, requester)
	}
	if plan.phase == opening {
		plan.closeRequested = true
		return
	}
	if plan.phase == active {
		c.startClose(ctx, plan)
	}
}

func (c *SessionCoordinator) startClose(ctx *actor.ReceiveContext, plan *sessionPlan) {
	plan.phase = closing
	plan.prepareAcks = make(map[application.RegistryKind]bool)
	plan.commitAcks = make(map[application.RegistryKind]bool)
	plan.agents = make(map[string]*actor.PID)
	plan.dropped = make(map[string]bool)
	c.sendPrepare(ctx, plan)
}

func (c *SessionCoordinator) prepareAck(ctx *actor.ReceiveContext, message *application.SessionPrepareAck) {
	plan := c.match(message.SessionID, message.GenerationID)
	if plan == nil || plan.phase != closing {
		return
	}
	plan.prepareAcks[message.Registry] = true
	for _, name := range message.AgentNames {
		if _, exists := plan.agents[name]; exists {
			continue
		}
		pid, err := ctx.ActorSystem().ActorOf(ctx.Context(), name)
		if err != nil {
			// AgentRegistry death watch removes terminated actors from future plans;
			// an actor that vanished during this plan is treated as terminated.
			plan.dropped[name] = true
			continue
		}
		plan.agents[name] = pid
		ctx.Watch(pid)
	}
	if len(plan.prepareAcks) == 2 {
		c.sendDropsOrCommit(ctx, plan)
	}
}

func (c *SessionCoordinator) dropAck(ctx *actor.ReceiveContext, message *application.SessionDropped) {
	plan := c.match(message.SessionID, message.GenerationID)
	if plan == nil || plan.phase != closing {
		return
	}
	plan.dropped[message.AgentName] = true
	c.sendDropsOrCommit(ctx, plan)
}

func (c *SessionCoordinator) terminated(ctx *actor.ReceiveContext, message *actor.Terminated) {
	name := message.ActorPath().Name()
	for _, plan := range c.plans {
		if plan.phase == closing {
			if _, exists := plan.agents[name]; exists {
				plan.dropped[name] = true
				c.sendDropsOrCommit(ctx, plan)
			}
		}
	}
}

func (c *SessionCoordinator) commitAck(ctx *actor.ReceiveContext, message *application.SessionCommitAck) {
	plan := c.match(message.SessionID, message.GenerationID)
	if plan == nil || (plan.phase != closing && plan.phase != compensating) {
		return
	}
	plan.commitAcks[message.Registry] = true
	if len(plan.commitAcks) != 2 {
		return
	}
	if plan.phase == compensating {
		c.respondOpen(plan, application.CoordinationResult{Reason: "session registration rejected"})
		c.respondClose(plan, application.CoordinationResult{Completed: true})
	} else {
		c.respondClose(plan, application.CoordinationResult{Completed: true})
	}
	delete(c.plans, plan.session.SessionID)
}

func (c *SessionCoordinator) retry(ctx *actor.ReceiveContext, sessionID, generationID string) {
	plan := c.match(sessionID, generationID)
	if plan == nil {
		return
	}
	plan.retryScheduled = false
	if plan.retryAttempts >= maxCoordinationRetries {
		switch {
		case plan.phase == closing:
			plan.retryAttempts = 0
		case plan.phase == opening && len(plan.openAcks) > 0:
			plan.phase = compensating
			plan.commitAcks = make(map[application.RegistryKind]bool)
			plan.retryAttempts = 0
			c.sendCommits(ctx, plan)
			return
		case plan.phase == compensating && len(plan.commitAcks) > 0:
			c.failPlan(plan, "session compensation retry limit exceeded")
			delete(c.plans, plan.session.SessionID)
			return
		default:
			c.failPlan(plan, "session coordination retry limit exceeded")
			delete(c.plans, plan.session.SessionID)
			return
		}
	}
	switch plan.phase {
	case opening:
		c.sendOpen(ctx, plan)
	case closing:
		if len(plan.prepareAcks) < 2 {
			c.sendPrepare(ctx, plan)
		} else {
			c.sendDropsOrCommit(ctx, plan)
		}
	case compensating:
		c.sendCommits(ctx, plan)
	}
}

func (c *SessionCoordinator) sendOpen(ctx *actor.ReceiveContext, plan *sessionPlan) {
	for registry, pid := range map[application.RegistryKind]*actor.PID{application.SessionRegistry: c.sessionRegistry, application.AgentRegistry: c.agentRegistry} {
		if !plan.openAcks[registry] {
			c.deliverOrRetry(ctx, pid, &application.StageSession{Session: plan.session, Registry: registry, Acknowledge: ctx.Self()}, plan)
		}
	}
}

func (c *SessionCoordinator) sendPrepare(ctx *actor.ReceiveContext, plan *sessionPlan) {
	for registry, pid := range map[application.RegistryKind]*actor.PID{application.SessionRegistry: c.sessionRegistry, application.AgentRegistry: c.agentRegistry} {
		if !plan.prepareAcks[registry] {
			c.deliverOrRetry(ctx, pid, &application.PrepareSessionClose{SessionID: plan.session.SessionID, GenerationID: plan.session.GenerationID, Registry: registry, Acknowledge: ctx.Self()}, plan)
		}
	}
}

func (c *SessionCoordinator) sendDropsOrCommit(ctx *actor.ReceiveContext, plan *sessionPlan) {
	for name, pid := range plan.agents {
		if !plan.dropped[name] {
			if !c.deliverDropOrRetry(ctx, pid, &application.DropSession{SessionID: plan.session.SessionID, GenerationID: plan.session.GenerationID, AgentName: name, Acknowledge: ctx.Self()}, plan) {
				plan.dropped[name] = true
			}
		}
	}
	if len(plan.dropped) == len(plan.agents) {
		c.sendCommits(ctx, plan)
	}
}

func (c *SessionCoordinator) sendCommits(ctx *actor.ReceiveContext, plan *sessionPlan) {
	for registry, pid := range map[application.RegistryKind]*actor.PID{application.SessionRegistry: c.sessionRegistry, application.AgentRegistry: c.agentRegistry} {
		if !plan.commitAcks[registry] {
			c.deliverOrRetry(ctx, pid, &application.CommitSessionClose{SessionID: plan.session.SessionID, GenerationID: plan.session.GenerationID, Registry: registry, Acknowledge: ctx.Self()}, plan)
		}
	}
}

func (c *SessionCoordinator) deliverOrRetry(ctx *actor.ReceiveContext, target *actor.PID, message any, plan *sessionPlan) {
	// NonBlockingBoundedMailbox overflow is dead-lettered and Tell may not
	// surface it to the sender. Schedule every unacknowledged step; duplicate
	// deliveries are idempotent and acknowledgements stop subsequent retries.
	_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), target, message)
	c.scheduleRetry(ctx, plan)
}

func (c *SessionCoordinator) deliverDropOrRetry(ctx *actor.ReceiveContext, target *actor.PID, message any, plan *sessionPlan) bool {
	err := ctx.Self().Tell(context.WithoutCancel(ctx.Context()), target, message)
	if err != nil && strings.Contains(err.Error(), "not alive") {
		return false
	}
	c.scheduleRetry(ctx, plan)
	return true
}
func (c *SessionCoordinator) scheduleRetry(ctx *actor.ReceiveContext, plan *sessionPlan) {
	if plan.retryScheduled {
		return
	}
	plan.retryAttempts++
	backoff := coordinationRetry << max(plan.retryAttempts-1, 0)
	if backoff > maxCoordinationBackoff {
		backoff = maxCoordinationBackoff
	}
	if err := ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &application.RetryCoordination{SessionID: plan.session.SessionID, GenerationID: plan.session.GenerationID}, ctx.Self(), backoff); err == nil {
		plan.retryScheduled = true
	}
}
func (c *SessionCoordinator) failPlan(plan *sessionPlan, reason string) {
	c.respondOpen(plan, application.CoordinationResult{Reason: reason})
	c.respondClose(plan, application.CoordinationResult{Reason: reason})
}

func (c *SessionCoordinator) respondOpen(plan *sessionPlan, response application.CoordinationResult) {
	for _, requester := range plan.openRequesters {
		deliverCoordinationResult(requester, response)
	}
	plan.openRequesters = nil
}

func (c *SessionCoordinator) respondClose(plan *sessionPlan, response application.CoordinationResult) {
	for _, requester := range plan.closeRequesters {
		deliverCoordinationResult(requester, response)
	}
	plan.closeRequesters = nil
}

func deliverCoordinationResult(requester chan<- application.CoordinationResult, response application.CoordinationResult) {
	if requester == nil {
		return
	}
	select {
	case requester <- response:
	default:
	}
}

func (c *SessionCoordinator) match(sessionID, generationID string) *sessionPlan {
	plan := c.plans[sessionID]
	if plan == nil || plan.session.GenerationID != generationID {
		return nil
	}
	return plan
}

func (c *SessionCoordinator) compactIdentityLedgers() {
	if len(c.usedSessions) < maxSessionIdentities && len(c.usedGenerations) < maxSessionIdentities {
		return
	}
	activeSessions := make(map[string]struct{}, len(c.plans))
	activeGenerations := make(map[string]struct{}, len(c.plans))
	for _, plan := range c.plans {
		activeSessions[plan.session.SessionID] = struct{}{}
		activeGenerations[plan.session.GenerationID] = struct{}{}
	}
	c.usedSessions, c.usedSessionOrder = compactIdentityLedger(c.usedSessions, c.usedSessionOrder, activeSessions)
	c.usedGenerations, c.usedGenerationOrder = compactIdentityLedger(c.usedGenerations, c.usedGenerationOrder, activeGenerations)
}

func compactIdentityLedger(used map[string]struct{}, order []string, active map[string]struct{}) (map[string]struct{}, []string) {
	limit := maxSessionIdentities - 1
	if len(active) > limit {
		limit = len(active)
	}
	kept := make(map[string]struct{}, min(len(used), maxSessionIdentities))
	for value := range active {
		if _, exists := used[value]; exists {
			kept[value] = struct{}{}
		}
	}
	for index := len(order) - 1; index >= 0 && len(kept) < limit; index-- {
		value := order[index]
		if _, exists := used[value]; !exists {
			continue
		}
		kept[value] = struct{}{}
	}
	compacted := make([]string, 0, len(kept))
	seen := make(map[string]struct{}, len(kept))
	for _, value := range order {
		if _, keep := kept[value]; !keep {
			continue
		}
		if _, duplicate := seen[value]; duplicate {
			continue
		}
		seen[value] = struct{}{}
		compacted = append(compacted, value)
	}
	return kept, compacted
}

func sameSession(left, right application.OpenSession) bool {
	return left.SessionID == right.SessionID && left.GenerationID == right.GenerationID && left.Caller == right.Caller && left.ExpiresAt.Equal(right.ExpiresAt) && left.Persistent == right.Persistent && string(left.Credential) == string(right.Credential) && slices.Equal(left.Capabilities, right.Capabilities)
}
func cloneSession(value application.OpenSession) application.OpenSession {
	value.Credential = append([]byte(nil), value.Credential...)
	value.Capabilities = append([]string(nil), value.Capabilities...)
	return value
}
