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
	case *actor.SubscribeAck, *application.AgentProjectionEvent, *application.PublicAgentDirectoryEvent:
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

func TestAgentRegistryPublishesHostedAvailabilityEvents(t *testing.T) {
	ctx := context.Background()
	system, err := actor.NewActorSystem("registry-public-events-test", actor.WithPubSub(), actor.WithMessageRetention(time.Minute))
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
	messages := make(chan any, 8)
	_, err = system.Spawn(ctx, "public-events-probe", &topicProbeActor{topic: "subagents.public.agents", messages: messages})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-messages:
	case <-time.After(time.Second):
		t.Fatal("TopicActor did not acknowledge public event subscription")
	}
	registry, err := system.Spawn(ctx, "agent-registry", actors.NewAgentRegistryActor())
	if err != nil {
		t.Fatal(err)
	}
	if err := system.NoSender().Tell(ctx, registry, &application.ConfigurePublicAgentEvents{NodeIdentity: "node-b", PlacementAuthority: application.HostedPlacementAuthorityName("node-b"), Epoch: 1}); err != nil {
		t.Fatal(err)
	}
	runtime := &registryRuntime{proc: &registryProcess{wait: make(chan struct{})}}
	result := make(chan application.RegisterAgentResult, 1)
	if err := system.NoSender().Tell(ctx, registry, &application.CoordinateAgentRegistration{OperationID: "register-public", Registration: hostedRegistration("public-hosted", runtime), Result: result}); err != nil {
		t.Fatal(err)
	}
	select {
	case registered := <-result:
		if !registered.Created {
			t.Fatalf("hosted registration failed: %#v", registered)
		}
	case <-time.After(time.Second):
		t.Fatal("hosted registration timed out")
	}
	upsert := waitPublicEvent(t, messages, "upsert")
	if upsert.NodeIdentity != "node-b" || upsert.AgentID != "public-hosted" || upsert.ActorName != application.HostedPlacementAuthorityName("node-b") || upsert.Epoch != 1 || upsert.Sequence == 0 || upsert.Reference.AuthorityBinding.Kind != application.AuthorityBindingHostedOwned {
		t.Fatalf("unexpected upsert event: %#v", upsert)
	}
	unregistered := make(chan application.UnregisterAgentResult, 1)
	if err := system.NoSender().Tell(ctx, registry, &application.UnregisterAgent{AgentID: "public-hosted", Result: unregistered}); err != nil {
		t.Fatal(err)
	}
	remove := waitPublicEvent(t, messages, "remove")
	if remove.NodeIdentity != "node-b" || remove.AgentID != "public-hosted" || remove.Sequence <= upsert.Sequence {
		t.Fatalf("unexpected remove event: %#v", remove)
	}
}

func waitPublicEvent(t *testing.T, messages <-chan any, operation string) *application.PublicAgentDirectoryEvent {
	t.Helper()
	deadline := time.After(time.Second)
	for {
		select {
		case message := <-messages:
			if event, ok := message.(*application.PublicAgentDirectoryEvent); ok && event.Operation == operation {
				return event
			}
		case <-deadline:
			t.Fatalf("timed out waiting for %s public event", operation)
		}
	}
}
