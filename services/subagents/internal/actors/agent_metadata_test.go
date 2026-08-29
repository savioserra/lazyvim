package actors

import (
	"context"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

func TestHostedRuntimeStateChangePreservesAuthoritativeDisplayMetadata(t *testing.T) {
	ctx := context.Background()
	system, err := actor.NewActorSystem("agent-metadata-test")
	if err != nil {
		t.Fatal(err)
	}
	if err := system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = system.Stop(context.Background()) })
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.RuntimeID = "runtime-one"
	binding.DisplayName = "Release Reviewer"
	binding.Role = "review"
	registration := &application.RegisterAgent{
		AgentID:          "reviewer",
		DisplayName:      binding.DisplayName,
		Role:             binding.Role,
		AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: binding.RuntimeID},
		HostedPiRuntime:  binding,
	}
	pid, err := system.Spawn(ctx, "metadata-agent", NewAgentActor(registration))
	if err != nil {
		t.Fatal(err)
	}
	update := application.InactiveHostedPiRuntimeBinding()
	update.RuntimeID = binding.RuntimeID
	update.State = application.HostedPiRuntimeStarting
	if err := system.NoSender().Tell(ctx, pid, &application.HostedPiRuntimeStateChanged{AgentID: "reviewer", Binding: update}); err != nil {
		t.Fatal(err)
	}
	value, err := system.NoSender().Ask(ctx, pid, &application.HostedPiRuntimeStatus{}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	status := value.(*application.HostedPiRuntimeBinding)
	if status.DisplayName != binding.DisplayName || status.Role != binding.Role {
		t.Fatalf("runtime update erased authoritative metadata: %#v", status)
	}
}
