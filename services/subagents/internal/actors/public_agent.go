package actors

import (
	"context"
	"crypto/subtle"
	"strings"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

// PublicAgentDirectoryActor authorizes before lookup/routing and keeps only a
// bounded public projection of remotely homed full AgentActor aggregates.
type PublicAgentDirectoryActor struct {
	localNode string
	nodes     map[string]application.PublicNode
	sessions  map[string]sessionRecord
	agents    map[string]application.PublicAgentRecord
}

func NewPublicAgentDirectoryActor(localNode string, nodes map[string]application.PublicNode) *PublicAgentDirectoryActor {
	copy := make(map[string]application.PublicNode, len(nodes))
	for id, node := range nodes {
		copy[id] = node
	}
	return &PublicAgentDirectoryActor{localNode: localNode, nodes: copy, sessions: make(map[string]sessionRecord), agents: make(map[string]application.PublicAgentRecord)}
}
func (*PublicAgentDirectoryActor) PreStart(*actor.Context) error { return nil }
func (*PublicAgentDirectoryActor) PostStop(*actor.Context) error { return nil }
func (d *PublicAgentDirectoryActor) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *application.StageSession:
		accepted := message.Registry == application.AgentRegistry && d.stage(message.Session)
		d.ack(ctx, message.Acknowledge, &application.SessionStageAck{SessionID: message.Session.SessionID, GenerationID: message.Session.GenerationID, Registry: application.AgentRegistry, Accepted: accepted})
	case *application.CommitSessionClose:
		if record, exists := d.sessions[message.SessionID]; exists && record.generationID == message.GenerationID {
			delete(d.sessions, message.SessionID)
		}
		d.ack(ctx, message.Acknowledge, &application.SessionCommitAck{SessionID: message.SessionID, GenerationID: message.GenerationID, Registry: application.AgentRegistry})
	case *application.CreatePublicAgent:
		d.upsert(ctx, message)
	case *application.ListAgents:
		if !d.authorized(message.SessionID, message.GenerationID, message.Caller, message.Credential, "observe") {
			ctx.Response(&application.AgentList{})
			return
		}
		agents := make([]application.AgentReference, 0, len(d.agents))
		for _, record := range d.agents {
			if !record.Private {
				agents = append(agents, record.Reference)
			}
		}
		ctx.Response(&application.AgentList{Agents: agents})
	case *application.LookupPublicAgent:
		if !d.authorized(message.SessionID, message.GenerationID, message.Caller, message.Credential, "observe") {
			ctx.Response(&application.PublicAgentLookupResult{Reason: "session authorization denied"})
			return
		}
		record, ok := d.agents[message.AgentID]
		if !ok || record.Private {
			ctx.Response(&application.PublicAgentLookupResult{Reason: "agent not found"})
			return
		}
		ctx.Response(&application.PublicAgentLookupResult{Found: true, Record: record})
	case *application.RoutePublicAgent:
		d.route(ctx, message)
	default:
		ctx.Unhandled()
	}
}

func (d *PublicAgentDirectoryActor) stage(message application.OpenSession) bool {
	if !validSession(message) {
		return false
	}
	capabilities := make(map[string]struct{}, len(message.Capabilities))
	for _, capability := range message.Capabilities {
		capabilities[capability] = struct{}{}
	}
	d.sessions[message.SessionID] = sessionRecord{generationID: message.GenerationID, caller: message.Caller, credential: append([]byte(nil), message.Credential...), capabilities: capabilities, expiresAt: message.ExpiresAt, persistent: message.Persistent}
	return true
}

func (d *PublicAgentDirectoryActor) upsert(ctx *actor.ReceiveContext, message *application.CreatePublicAgent) {
	if !message.Internal && !d.authorized(message.SessionID, message.GenerationID, message.Caller, message.Credential, "admin") {
		ctx.Response(&application.PublicAgentCreateResult{Reason: "session authorization denied"})
		return
	}
	if message.Private || boundedPublicID(message.AgentID) == "" || message.Placement.NodeIdentity == "" || message.Placement.NodeIdentity == d.localNode {
		ctx.Response(&application.PublicAgentCreateResult{Reason: "invalid public agent"})
		return
	}
	node, ok := d.nodes[message.Placement.NodeIdentity]
	if !ok || node.Stale || node.Host == "" || node.Port <= 0 {
		ctx.Response(&application.PublicAgentCreateResult{Reason: "placement node unavailable"})
		return
	}
	record := messageRecord(message, node)
	d.agents[message.AgentID] = record
	ctx.Response(&application.PublicAgentCreateResult{Created: true, Record: record})
}

func messageRecord(message *application.CreatePublicAgent, node application.PublicNode) application.PublicAgentRecord {
	reference := message.Reference
	if reference.AgentID == "" {
		reference = application.AgentReference{AgentID: message.AgentID, LifecycleRevision: 1, Role: boundedDisplayMetadata(message.Role, 64), DisplayName: boundedDisplayMetadata(message.DisplayName, 80)}
	}
	return application.PublicAgentRecord{AgentID: message.AgentID, ActorName: message.ActorName, HomeNode: node.Identity, Host: node.Host, Port: node.Port, Role: reference.Role, DisplayName: reference.DisplayName, Revision: reference.LifecycleRevision, Reference: reference}
}

func (d *PublicAgentDirectoryActor) route(ctx *actor.ReceiveContext, message *application.RoutePublicAgent) {
	if !d.authorizedAll(message.SessionID, message.GenerationID, message.Caller, message.Credential, message.Capabilities) {
		ctx.Response(&application.PublicAgentRouteResult{Reason: "session authorization denied"})
		return
	}
	record, ok := d.agents[message.AgentID]
	if !ok || record.Private {
		ctx.Response(&application.PublicAgentRouteResult{Reason: "agent not found"})
		return
	}
	node, ok := d.nodes[record.HomeNode]
	if !ok || node.Stale || node.Host != record.Host || node.Port != record.Port {
		ctx.Response(&application.PublicAgentRouteResult{Reason: "home node unavailable"})
		return
	}
	ctx.Response(&application.PublicAgentRouteResult{Allowed: true, Record: record})
}

func (d *PublicAgentDirectoryActor) authorizedAll(sessionID, generationID, caller string, credential []byte, capabilities []string) bool {
	if len(capabilities) == 0 {
		return false
	}
	for _, capability := range capabilities {
		if !d.authorized(sessionID, generationID, caller, credential, capability) {
			return false
		}
	}
	return true
}
func (d *PublicAgentDirectoryActor) authorized(sessionID, generationID, caller string, credential []byte, capability string) bool {
	record, ok := d.sessions[sessionID]
	if !ok || record.closing || generationID == "" || record.generationID != generationID || record.caller != caller || (!record.persistent && !record.expiresAt.After(time.Now())) || len(record.credential) != len(credential) || subtle.ConstantTimeCompare(record.credential, credential) != 1 {
		return false
	}
	_, ok = record.capabilities[capability]
	return ok
}
func (*PublicAgentDirectoryActor) ack(ctx *actor.ReceiveContext, target *actor.PID, message any) {
	if target != nil {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), target, message)
	}
}

func boundedPublicID(value string) string {
	value = strings.TrimSpace(value)
	if len(value) > 128 {
		value = value[:128]
	}
	for _, r := range value {
		if !(r == '_' || r == '-' || r == '.' || r >= '0' && r <= '9' || r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z') {
			return ""
		}
	}
	return value
}
