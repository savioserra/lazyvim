package service

import (
	"context"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

const actorReplyReconcileInterval = 250 * time.Millisecond

type actorReplyReconcileTick struct{}
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
		b.scheduleReconcile(ctx)
	case *actor.SubscribeAck:
		return
	case *actorReplyReconcileTick:
		if b.service != nil {
			b.service.flushAllActorReplies()
		}
		b.scheduleReconcile(ctx)
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
			b.service.pushRegularDeliveryUpdate(message.TargetAgentID, "actor delivery committed")
		}
	}
}

func (*actorReplyBroker) scheduleReconcile(ctx *actor.ReceiveContext) {
	_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &actorReplyReconcileTick{}, ctx.Self(), actorReplyReconcileInterval)
}
