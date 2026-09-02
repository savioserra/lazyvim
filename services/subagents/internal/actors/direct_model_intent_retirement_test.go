package actors_test

import (
	"context"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
)

func TestAgentRejectsDirectModelBearingBridgeIntentsBeforeEffects(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("direct-model-intent-retirement")
	if err != nil {
		t.Fatal(err)
	}
	if err := system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		stop, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = system.Stop(stop)
	})
	registration := &application.RegisterAgent{AgentID: "target", HostedPiRuntime: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, RuntimeID: "runtime", Incarnation: 1}, AllowedCapability: []string{"ask", "prompt"}, Retention: "explicit", Recovery: "owned"}
	pid, err := system.Spawn(ctx, "direct-model-target", actors.NewAgentActor(registration))
	if err != nil {
		t.Fatal(err)
	}
	for _, message := range []any{
		&application.BridgeIntent{Mode: application.BridgeMessageAsk, Payload: []byte("work")},
		&application.BridgeIntent{Mode: application.BridgeMessagePrompt, Payload: []byte("work")},
		&application.RemoteBridgeIntent{Mode: application.BridgeMessageAsk, Payload: []byte("work"), ReplyTopic: application.ActorMessageReplyTopic},
		&application.RemoteBridgeIntent{Mode: application.BridgeMessagePrompt, Payload: []byte("work"), ReplyTopic: application.ActorMessageReplyTopic},
	} {
		value, askErr := system.NoSender().Ask(ctx, pid, message, time.Second)
		if askErr != nil {
			t.Fatal(askErr)
		}
		result, ok := value.(*application.BridgeIntentResult)
		if !ok || result.Accepted || result.Reason != "model-bearing bridge intent retired; use actor task" {
			t.Fatalf("direct model intent was not rejected fail-closed: %#v", value)
		}
	}
}
