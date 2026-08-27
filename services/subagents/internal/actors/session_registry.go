package actors

import (
	"context"
	"crypto/subtle"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

type sessionRecord struct {
	generationID string
	caller       string
	credential   []byte
	capabilities map[string]struct{}
	expiresAt    time.Time
	persistent   bool
	closing      bool
}

// SessionRegistryActor owns only ephemeral access contexts. Session lifecycle
// mutations are accepted exclusively from SessionCoordinator's ack protocol.
type SessionRegistryActor struct{ sessions map[string]sessionRecord }

func NewSessionRegistryActor() *SessionRegistryActor {
	return &SessionRegistryActor{sessions: make(map[string]sessionRecord)}
}
func (*SessionRegistryActor) PreStart(*actor.Context) error { return nil }
func (*SessionRegistryActor) PostStop(*actor.Context) error { return nil }
func (a *SessionRegistryActor) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *application.StageSession:
		accepted := message.Registry == application.SessionRegistry && a.stage(message.Session)
		a.ack(ctx, message.Acknowledge, &application.SessionStageAck{SessionID: message.Session.SessionID, GenerationID: message.Session.GenerationID, Registry: application.SessionRegistry, Accepted: accepted})
	case *application.PrepareSessionClose:
		if record, exists := a.sessions[message.SessionID]; exists && record.generationID == message.GenerationID {
			record.closing = true
			a.sessions[message.SessionID] = record
		}
		a.ack(ctx, message.Acknowledge, &application.SessionPrepareAck{SessionID: message.SessionID, GenerationID: message.GenerationID, Registry: application.SessionRegistry})
	case *application.CommitSessionClose:
		if record, exists := a.sessions[message.SessionID]; exists && record.generationID == message.GenerationID {
			delete(a.sessions, message.SessionID)
		}
		a.ack(ctx, message.Acknowledge, &application.SessionCommitAck{SessionID: message.SessionID, GenerationID: message.GenerationID, Registry: application.SessionRegistry})
	case *application.SessionAuthorization:
		record, ok := a.sessions[message.SessionID]
		allowed := ok && !record.closing && message.GenerationID != "" && record.generationID == message.GenerationID && record.caller == message.Caller && (record.persistent || record.expiresAt.After(time.Now())) && len(record.credential) == len(message.Credential) && subtle.ConstantTimeCompare(record.credential, message.Credential) == 1
		if allowed && message.Capability != "" {
			_, allowed = record.capabilities[message.Capability]
		}
		ctx.Response(&application.AuthorizationResult{Allowed: allowed, GenerationID: record.generationID})
	default:
		ctx.Unhandled()
	}
}

func (a *SessionRegistryActor) stage(message application.OpenSession) bool {
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
	a.sessions[message.SessionID] = sessionRecord{generationID: message.GenerationID, caller: message.Caller, credential: append([]byte(nil), message.Credential...), capabilities: capabilities, expiresAt: message.ExpiresAt, persistent: message.Persistent}
	return true
}

func (*SessionRegistryActor) ack(ctx *actor.ReceiveContext, target *actor.PID, message any) {
	if target != nil {
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), target, message)
	}
}
func validSession(message application.OpenSession) bool {
	return message.SessionID != "" && message.GenerationID != "" && message.Caller != "" && len(message.Credential) >= 32 && (message.Persistent || message.ExpiresAt.After(time.Now()))
}
func sameSessionRecord(record sessionRecord, message application.OpenSession) bool {
	return record.generationID == message.GenerationID && record.caller == message.Caller && record.expiresAt.Equal(message.ExpiresAt) && record.persistent == message.Persistent && string(record.credential) == string(message.Credential)
}
