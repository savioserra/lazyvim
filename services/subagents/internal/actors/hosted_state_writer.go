package actors

import (
	"context"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

// HostedStateWriterActor is the direct supervised GoAkt effect boundary. Its
// Receive only captures immutable work; fsync executes asynchronously and
// reports a typed completion to the owning actor.
type HostedStateWriterActor struct{ Store application.DurableStore }

func (*HostedStateWriterActor) PreStart(*actor.Context) error { return nil }
func (*HostedStateWriterActor) PostStop(*actor.Context) error { return nil }
func (a *HostedStateWriterActor) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *application.PersistDurableHostedState:
		record, owner, correlation, store, system := message.Record, message.Owner, message.Correlation, a.Store, ctx.ActorSystem()
		go func() {
			err := store.Save(context.Background(), record)
			if owner != nil {
				_ = system.NoSender().Tell(context.Background(), owner, &application.DurableHostedStatePersisted{Correlation: correlation, Err: err})
			}
		}()
	case *application.RemoveDurableHostedState:
		agentID, owner, correlation, store, system := message.AgentID, message.Owner, message.Correlation, a.Store, ctx.ActorSystem()
		go func() {
			err := store.Remove(context.Background(), agentID)
			if owner != nil {
				_ = system.NoSender().Tell(context.Background(), owner, &application.DurableHostedStateRemoved{Correlation: correlation, Err: err})
			}
		}()
	default:
		ctx.Unhandled()
	}
}
