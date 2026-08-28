package actors

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"strings"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

// PublicAgentActor is the only remotely placeable public AgentActor kind. It is
// actor-plane only: it never owns hosted runtimes and never exposes UDS state.
type PublicAgentActor struct {
	AgentID     string
	Role        string
	DisplayName string
}

func NewPublicAgentActor(agentID, role, displayName string) *PublicAgentActor {
	return &PublicAgentActor{AgentID: boundedPublicID(agentID), Role: boundedDisplayMetadata(role, 64), DisplayName: boundedDisplayMetadata(displayName, 80)}
}
func (*PublicAgentActor) PreStart(*actor.Context) error { return nil }
func (*PublicAgentActor) PostStop(*actor.Context) error { return nil }
func (a *PublicAgentActor) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *application.PublicAgentTell:
		ctx.Response(&application.PublicAgentReply{Accepted: true, Completed: true, AgentID: a.AgentID, Payload: append([]byte(nil), message.Payload...)})
	case *application.PublicAgentAsk:
		ctx.Response(&application.PublicAgentReply{Accepted: true, Completed: true, AgentID: a.AgentID, Payload: append([]byte(nil), message.Payload...)})
	default:
		ctx.Unhandled()
	}
}

// PublicAgentDirectoryActor authorizes before lookup/routing and keeps only a
// bounded, public projection. Private registrations are deliberately excluded.
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
		d.create(ctx, message)
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

func (d *PublicAgentDirectoryActor) create(ctx *actor.ReceiveContext, message *application.CreatePublicAgent) {
	if !d.authorized(message.SessionID, message.GenerationID, message.Caller, message.Credential, "admin") {
		ctx.Response(&application.PublicAgentCreateResult{Reason: "session authorization denied"})
		return
	}
	agentID := boundedPublicID(message.AgentID)
	if agentID == "" || message.Private {
		ctx.Response(&application.PublicAgentCreateResult{Reason: "invalid public agent"})
		return
	}
	node, ok := d.nodes[message.Placement.NodeIdentity]
	if !ok || node.Stale || node.Host == "" || node.Port <= 0 {
		ctx.Response(&application.PublicAgentCreateResult{Reason: "placement node unavailable"})
		return
	}
	if current, exists := d.agents[agentID]; exists {
		ctx.Response(&application.PublicAgentCreateResult{Created: false, Record: current, Reason: "already registered"})
		return
	}
	name := PublicAgentActorName(agentID)
	pid, err := ctx.ActorSystem().Spawn(ctx.Context(), name, NewPublicAgentActor(agentID, message.Role, message.DisplayName), actor.WithHostAndPort(node.Host, node.Port), actor.WithRelocationDisabled())
	if err != nil {
		ctx.Response(&application.PublicAgentCreateResult{Reason: err.Error()})
		return
	}
	record := application.PublicAgentRecord{AgentID: agentID, ActorName: name, HomeNode: node.Identity, Host: node.Host, Port: node.Port, Role: boundedDisplayMetadata(message.Role, 64), DisplayName: boundedDisplayMetadata(message.DisplayName, 80), Revision: 1}
	d.agents[agentID] = record
	ctx.Response(&application.PublicAgentCreateResult{Created: true, Record: record, PID: pid})
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
	pid := ctx.RemoteLookup(record.Host, record.Port, record.ActorName)
	if pid == nil {
		ctx.Response(&application.PublicAgentRouteResult{Reason: "agent unavailable"})
		return
	}
	ctx.Response(&application.PublicAgentRouteResult{Allowed: true, PID: pid, Record: record})
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

func PublicAgentActorName(agentID string) string {
	digest := sha256.Sum256([]byte("public-agent\x00" + agentID))
	return "public-agent-" + hex.EncodeToString(digest[:8])
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
