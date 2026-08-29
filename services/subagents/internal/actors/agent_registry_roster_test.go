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

func TestAgentRegistryClientRosterSnapshotIsAuthorizedAndMonotonic(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	kit.Spawn(ctx, "agent-registry", actors.NewAgentRegistryActor())
	probe := kit.NewProbe(ctx)
	credential := []byte(strings.Repeat("r", 32))
	openSession(t, probe, "roster-session", "generation", "client:ui", credential, time.Now().Add(time.Hour))
	registration := registration("roster-agent", "observe")
	registration.DisplayName = "Roster Agent"
	registration.Role = "Reviewer"
	if result := coordinateRegistration(t, kit, registration, "register-roster-agent"); !result.Created {
		t.Fatalf("registration failed: %#v", result)
	}
	value, err := kit.ActorSystem().NoSender().Ask(ctx, mustActor(t, kit, "agent-registry"), &application.ClientAgentRosterSnapshot{SessionID: "roster-session", GenerationID: "generation", Caller: "client:ui", Credential: credential}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	snapshot := value.(*application.ClientAgentRosterSnapshotResult)
	if snapshot.Reason != "" || len(snapshot.Events) != 2 {
		t.Fatalf("unexpected roster snapshot: %#v", snapshot)
	}
	if snapshot.Events[0].Operation != application.ClientAgentRosterSnapshotReset || snapshot.Events[1].Operation != application.ClientAgentRosterUpsert || snapshot.Events[1].Reference.DisplayName != "Roster Agent" {
		t.Fatalf("snapshot did not carry authoritative lifecycle metadata: %#v", snapshot.Events)
	}
	if snapshot.Events[0].Epoch == 0 || snapshot.Events[1].Sequence <= snapshot.Events[0].Sequence {
		t.Fatalf("snapshot fencing was not monotonic: %#v", snapshot.Events)
	}
	denied, err := kit.ActorSystem().NoSender().Ask(ctx, mustActor(t, kit, "agent-registry"), &application.ClientAgentRosterSnapshot{SessionID: "roster-session", GenerationID: "generation", Caller: "client:ui", Credential: []byte(strings.Repeat("x", 32))}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if denied.(*application.ClientAgentRosterSnapshotResult).Reason == "" {
		t.Fatal("unauthenticated roster snapshot was accepted")
	}
}
