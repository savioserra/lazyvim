package actors_test

import (
	"context"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
)

func TestHostedBridgePinsPiSessionIdempotentlyAndRequiresFencedReplacement(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("bridge-binding-test")
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
	registration := &application.RegisterAgent{AgentID: "agent", HostedPiRuntime: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeReady, RuntimeID: "runtime", Incarnation: 1, BridgeReady: true}, AllowedCapability: []string{"hosted_bridge", "observe"}, Retention: "explicit", Recovery: "owned"}
	pid, err := system.Spawn(ctx, "bridge-binding-agent", actors.NewAgentActor(registration))
	if err != nil {
		t.Fatal(err)
	}
	runtime, _ := system.Spawn(ctx, "bridge-binding-runtime", &inertRuntimeActor{})
	_ = system.NoSender().Tell(ctx, pid, &application.BindHostedPiRuntimeActor{PID: runtime})
	ask := func(message any) any {
		value, err := system.NoSender().Ask(ctx, pid, message, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	attached := ask(&application.AttachAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:agent", RequestedCapabilities: []string{"hosted_bridge", "observe"}, IssuedHandle: "handle-one"}).(*application.AttachResult)
	first := ask(&application.BridgeConnect{SessionID: "session", GenerationID: "generation", Principal: "hosted:agent", AgentID: "agent", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime", Incarnation: 1, PiSessionID: "pi-one"}).(*application.BridgeResult)
	reconnect := ask(&application.BridgeConnect{SessionID: "session", GenerationID: "generation", Principal: "hosted:agent", AgentID: "agent", RuntimeID: "runtime", Incarnation: 1, PiSessionID: "pi-one"}).(*application.BridgeResult)
	if !reconnect.Accepted || reconnect.Handle != first.Handle || reconnect.Fence != first.Fence {
		t.Fatalf("same Pi session reconnect rotated its fence: %#v %#v", first, reconnect)
	}
	if ask(&application.BridgeConnect{SessionID: "session", GenerationID: "generation", Principal: "hosted:agent", AgentID: "agent", RuntimeID: "runtime", Incarnation: 1, PiSessionID: "pi-foreign"}).(*application.BridgeResult).Accepted {
		t.Fatal("different Pi session replaced the bridge without a fenced transition")
	}
	replaced := ask(&application.BridgeReplace{SessionID: "session", GenerationID: "generation", Principal: "hosted:agent", AgentID: "agent", Handle: first.Handle, Fence: first.Fence, RuntimeID: "runtime", Incarnation: 1, PreviousPiSessionID: "pi-one", NewPiSessionID: "pi-two", NewHandle: "handle-two"}).(*application.BridgeResult)
	if !replaced.Accepted || replaced.Fence == first.Fence || replaced.Handle != "handle-two" {
		t.Fatalf("explicit replacement did not fence old bridge: %#v", replaced)
	}
	if ask(&application.BridgeLifecycle{SessionID: "session", GenerationID: "generation", Principal: "hosted:agent", AgentID: "agent", Handle: first.Handle, Fence: first.Fence, RuntimeID: "runtime", Incarnation: 1, Event: application.BridgeLifecycleReady}).(*application.BridgeResult).Accepted {
		t.Fatal("old bridge fence survived replacement")
	}
	ask(&application.DropSession{SessionID: "session", GenerationID: "generation"})
	newAttach := ask(&application.AttachAgent{SessionID: "session-two", GenerationID: "generation-two", Principal: "hosted:agent", RequestedCapabilities: []string{"hosted_bridge", "observe"}, IssuedHandle: "handle-three"}).(*application.AttachResult)
	newConnect := ask(&application.BridgeConnect{SessionID: "session-two", GenerationID: "generation-two", Principal: "hosted:agent", AgentID: "agent", Handle: newAttach.Handle, Fence: newAttach.Fence, RuntimeID: "runtime", Incarnation: 1, PiSessionID: "pi-three"}).(*application.BridgeResult)
	if !newConnect.Accepted {
		t.Fatalf("dropped generation left stale bridge binding: %#v", newConnect)
	}
}
