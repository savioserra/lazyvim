package service

import (
	"context"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

type watchBridgeSession struct{ pid *actor.PID }

type bridgeSessionWatcher struct{ service *Service }

func (*bridgeSessionWatcher) PreStart(*actor.Context) error { return nil }
func (*bridgeSessionWatcher) PostStop(*actor.Context) error { return nil }
func (w *bridgeSessionWatcher) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *watchBridgeSession:
		if message.pid != nil {
			ctx.Watch(message.pid)
		}
	case *actor.Terminated:
		w.service.removeBridgeSessionActorName(message.ActorPath().Name())
	default:
		ctx.Unhandled()
	}
}

type bridgeSessionActor struct {
	service *Service
	session *bridgePushSession
	busy    bool
	closed  bool
	pending string
}

func newBridgeSessionActor(service *Service, session *bridgePushSession) *bridgeSessionActor {
	return &bridgeSessionActor{service: service, session: session}
}
func (*bridgeSessionActor) PreStart(*actor.Context) error { return nil }
func (a *bridgeSessionActor) PostStop(ctx *actor.Context) error {
	a.service.removeBridgeSessionActorName(ctx.ActorName())
	return nil
}
func (a *bridgeSessionActor) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *application.BridgeSessionAgentUpdate:
		if message.AgentID != "" && message.AgentID != a.session.agentID {
			return
		}
		a.schedulePush(ctx, message.Reason)
	case *application.BridgeSessionClosed:
		a.closed = true
	case *application.BridgeSessionPushCompleted:
		a.busy = false
		if message.Advanced && a.pending != "" {
			reason := a.pending
			a.pending = ""
			a.schedulePush(ctx, reason)
		}
	default:
		ctx.Unhandled()
	}
}

func (a *bridgeSessionActor) schedulePush(ctx *actor.ReceiveContext, reason string) {
	if a.closed {
		return
	}
	if reason == "" {
		reason = "bridge update"
	}
	if a.busy {
		a.pending = reason
		return
	}
	a.busy = true
	self, system, service, session := ctx.Self(), ctx.ActorSystem(), a.service, a.session
	go func() {
		advanced := service.pushBridgeToSession(session, reason)
		_ = system.NoSender().Tell(context.Background(), self, &application.BridgeSessionPushCompleted{Advanced: advanced, Reason: reason})
	}()
}
