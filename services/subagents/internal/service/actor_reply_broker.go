package service

import (
	"context"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

type actorReplyBroker struct{ service *Service }

func (*actorReplyBroker) PreStart(*actor.Context) error { return nil }
func (*actorReplyBroker) PostStop(*actor.Context) error { return nil }

func (b *actorReplyBroker) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *actor.PostStart:
		if topic := ctx.ActorSystem().TopicActor(); topic != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), topic, actor.NewSubscribe(application.ActorMessageReplyTopic))
		}
	case *actor.SubscribeAck:
		return
	case *application.ActorMessageReply:
		if b.service != nil {
			b.service.recordActorMessageReply(ctx.Context(), message)
		}
	}
}
