package actors_test

import (
	"context"
	"crypto/sha256"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

type topicProbeActor struct {
	topic    string
	messages chan<- any
}

func (*topicProbeActor) PreStart(*actor.Context) error { return nil }
func (*topicProbeActor) PostStop(*actor.Context) error { return nil }
func (p *topicProbeActor) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *actor.PostStart:
		ctx.Tell(ctx.ActorSystem().TopicActor(), actor.NewSubscribe(p.topic))
	case *actor.SubscribeAck, *application.AgentProjectionEvent:
		p.messages <- message
	default:
		ctx.Unhandled()
	}
}

func TestAgentProjectionUsesRealGoAktPubSubAndMessageIDRetention(t *testing.T) {
	ctx := context.Background()
	system, err := actor.NewActorSystem("agent-pubsub-test", actor.WithPubSub(), actor.WithMessageRetention(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if err := system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		stopCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = system.Stop(stopCtx)
	})

	messages := make(chan any, 4)
	_, err = system.Spawn(ctx, "projection-probe", &topicProbeActor{topic: "subagents.agent.pubsub-agent", messages: messages})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-messages:
	case <-time.After(time.Second):
		t.Fatal("TopicActor did not acknowledge Subscribe")
	}
	registration := registration("pubsub-agent", "observe", "steer")
	agent, err := system.Spawn(ctx, "pubsub-agent", actors.NewAgentActor(&registration))
	if err != nil {
		t.Fatal(err)
	}
	attachedAny, err := system.NoSender().Ask(ctx, agent, &application.AttachAgent{SessionID: "session", GenerationID: "generation", Principal: "caller", RequestedCapabilities: []string{"observe", "steer"}, IssuedHandle: "handle"}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	attached := attachedAny.(*application.AttachResult)
	command := &application.AgentCommand{SessionID: "session", GenerationID: "generation", Principal: "caller", Handle: attached.Handle, Fence: attached.Fence, Capability: "steer", Operation: "steer", RequestID: "command", PayloadDigest: sha256.Sum256([]byte("payload"))}
	for attempt := 0; attempt < 2; attempt++ {
		result, askErr := system.NoSender().Ask(ctx, agent, command, time.Second)
		if askErr != nil || !result.(*application.CommandResult).Completed {
			t.Fatalf("command attempt %d failed: %#v %v", attempt, result, askErr)
		}
	}
	select {
	case event := <-messages:
		projection, ok := event.(*application.AgentProjectionEvent)
		if !ok || projection.AgentID != "pubsub-agent" || projection.CommandSequence != 1 {
			t.Fatalf("unexpected TopicActor projection: %#v", event)
		}
	case <-time.After(time.Second):
		t.Fatal("TopicActor did not publish projection")
	}
	select {
	case duplicate := <-messages:
		t.Fatalf("deduplicated command republished: %#v", duplicate)
	case <-time.After(50 * time.Millisecond):
	}
}
