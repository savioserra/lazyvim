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
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), topic, actor.NewSubscribe(application.TargetTaskCommittedTopic))
		}
	case *actor.SubscribeAck:
		return
	case *application.ActorMessageReply:
		// Legacy migration adapter only; authoritative completion state must be in
		// the source AgentActor mailbox.
		if b.service != nil {
			b.service.recordActorMessageReply(ctx.Context(), message)
		}
	case *application.ActorTaskCompleted:
		if b.service != nil {
			b.service.flushActorReplyPrincipal(message.Source.StableID)
		}
	case *application.TargetTaskCommitted:
		if b.service != nil {
			b.service.pushBridgeUpdate(message.TargetAgentID, "actor delivery committed")
		}
	}
}
