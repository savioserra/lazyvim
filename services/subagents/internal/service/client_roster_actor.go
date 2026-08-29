package service

import (
	"context"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

type clientRosterFlush struct{}
type clientRosterClosed struct{}

type clientRosterActor struct {
	service *Service
	session *clientRosterSession
	closed  bool
}

func newClientRosterActor(service *Service, session *clientRosterSession) *clientRosterActor {
	return &clientRosterActor{service: service, session: session}
}

func (*clientRosterActor) PreStart(*actor.Context) error { return nil }
func (*clientRosterActor) PostStop(*actor.Context) error { return nil }

func (a *clientRosterActor) Receive(ctx *actor.ReceiveContext) {
	if a.closed {
		return
	}
	switch message := ctx.Message().(type) {
	case *actor.PostStart:
		if topic := ctx.ActorSystem().TopicActor(); topic != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), topic, actor.NewSubscribe(application.ClientAgentRosterTopic))
		}
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), ctx.Self(), &clientRosterFlush{})
	case *actor.SubscribeAck:
	case *clientRosterFlush:
		a.flushSnapshot(ctx)
	case *clientRosterClosed:
		a.closed = true
	case *application.ClientAgentRosterEvent:
		if ok := a.service.pushClientRosterToSession(a.session, []application.ClientAgentRosterEvent{*message}); !ok {
			a.closed = true
			a.service.removeClientRosterActorName(ctx.Self().Name())
			_ = ctx.Self().Shutdown(context.Background())
		}
	default:
		ctx.Unhandled()
	}
}

func (a *clientRosterActor) flushSnapshot(ctx *actor.ReceiveContext) {
	request := &application.ClientAgentRosterSnapshot{SessionID: a.session.sessionID, GenerationID: a.session.generationID, Caller: a.session.principal, Credential: append([]byte(nil), a.session.credential...), LastEpoch: a.session.lastEpoch, AfterSequence: a.session.afterSequence}
	value, err := ctx.ActorSystem().NoSender().Ask(ctx.Context(), a.service.agentRegistry, request, requestTimeout)
	if err != nil {
		return
	}
	result, ok := value.(*application.ClientAgentRosterSnapshotResult)
	if !ok || result.Reason != "" {
		return
	}
	if ok := a.service.pushClientRosterToSession(a.session, result.Events); !ok {
		a.closed = true
		a.service.removeClientRosterActorName(ctx.Self().Name())
		_ = ctx.Self().Shutdown(context.Background())
	}
}
