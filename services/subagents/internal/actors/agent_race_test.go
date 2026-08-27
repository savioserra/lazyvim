package actors_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/testkit"
)

func TestClosePlanCleansAttachAuthorizedBeforeRevocationButDeliveredLate(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	kit.Spawn(ctx, "agent-registry", actors.NewAgentRegistryActor())
	probe := kit.NewProbe(ctx)
	credential := []byte(strings.Repeat("r", 32))
	openSession(t, probe, "race-session", "race-generation", "race-caller", credential, time.Now().Add(time.Hour))
	if result := coordinateRegistration(t, kit, registration("race-agent", "observe"), "register-race"); !result.Created {
		t.Fatalf("registration failed: %#v", result)
	}
	route := authorizedRoute(t, probe, "race-session", "race-generation", "race-caller", credential, "race-agent", []string{"observe"})

	// Authorization happened before close. The routed Attach is deliberately
	// delivered only after the registry has revoked the generation.
	probe.Send("agent-registry", &application.PrepareSessionClose{SessionID: "race-session", GenerationID: "race-generation", Registry: application.AgentRegistry, Acknowledge: probe.PID()})
	plan := probe.ExpectAnyMessage().(*application.SessionPrepareAck)
	if len(plan.AgentNames) != 1 {
		t.Fatalf("unexpected cleanup plan: %#v", plan)
	}
	value, err := kit.ActorSystem().NoSender().Ask(ctx, route.PID, &application.AttachAgent{SessionID: "race-session", GenerationID: "race-generation", Principal: "race-caller", RequestedCapabilities: []string{"observe"}, IssuedHandle: "delayed-handle"}, time.Second)
	if err != nil || !value.(*application.AttachResult).Completed {
		t.Fatalf("test did not establish delayed attach race: %#v %v", value, err)
	}
	agent, resolveErr := kit.ActorSystem().ActorOf(ctx, plan.AgentNames[0])
	if resolveErr != nil {
		t.Fatal(resolveErr)
	}
	value, err = kit.ActorSystem().NoSender().Ask(ctx, agent, &application.DropSession{SessionID: plan.SessionID, GenerationID: plan.GenerationID}, time.Second)
	if err != nil || !value.(*application.OperationResult).Completed {
		t.Fatalf("cleanup did not complete: %#v %v", value, err)
	}
	value, err = kit.ActorSystem().NoSender().Ask(ctx, route.PID, &application.SubscribeAgent{SessionID: "race-session", GenerationID: "race-generation", Principal: "race-caller", Handle: "delayed-handle", Fence: 1}, time.Second)
	if err != nil || value.(*application.OperationResult).Completed {
		t.Fatalf("delayed attach survived completed close: %#v %v", value, err)
	}
}
