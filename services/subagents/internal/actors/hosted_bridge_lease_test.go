package actors_test

import (
	"context"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
)

func TestBridgeReadinessLeaseExpiresRejectsAndRecoversWithoutStaleTimer(t *testing.T) {
	ctx := context.Background()
	system, err := goakt.NewActorSystem("hosted-lease")
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
	registration := &application.RegisterAgent{AgentID: "target", HostedPiRuntime: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, RuntimeID: "runtime", Incarnation: 1}, AllowedCapability: []string{"hosted_bridge", "send"}, Retention: "explicit", Recovery: "owned"}
	pid, _ := system.Spawn(ctx, "lease-agent", actors.NewAgentActor(registration))
	runtime, _ := system.Spawn(ctx, "lease-runtime", &inertRuntimeActor{})
	_ = system.NoSender().Tell(ctx, pid, &application.BindHostedPiRuntimeActor{PID: runtime})
	ask := func(message any) any {
		value, err := system.NoSender().Ask(ctx, pid, message, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	attached := ask(&application.AttachAgent{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", RequestedCapabilities: []string{"hosted_bridge", "send"}, IssuedHandle: "handle"}).(*application.AttachResult)
	connect := &application.BridgeConnect{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", AgentID: "target", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime", Incarnation: 1, PiSessionID: "pi"}
	ask(connect)
	ask(&application.BridgeLifecycle{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", AgentID: "target", Handle: attached.Handle, Fence: attached.Fence, RuntimeID: "runtime", Incarnation: 1, Event: application.BridgeLifecycleReady})
	time.Sleep(600 * time.Millisecond)
	reconnect := *connect
	reconnect.Handle, reconnect.Fence = "", 0
	if !ask(&reconnect).(*application.BridgeResult).Accepted {
		t.Fatal("same-session lease reconnect failed")
	}
	time.Sleep(500 * time.Millisecond)
	var mutationSequence uint64
	intent := func(id string) *application.BridgeIntent {
		mutationSequence++
		return &application.BridgeIntent{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, SourceMutationSequence: mutationSequence, SourceAgentID: "source", TargetAgentID: "target", RequestID: id, RequiredCapability: "send", DedupeID: id, ChainID: "chain-" + id, Deadline: time.Now().Add(time.Second), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: []byte("notification")}
	}
	if !ask(intent("stale-timer-proof")).(*application.BridgeIntentResult).Accepted {
		t.Fatal("stale lease timer revoked a renewed bridge")
	}
	time.Sleep(600 * time.Millisecond)
	if ask(intent("expired")).(*application.BridgeIntentResult).Accepted {
		t.Fatal("delivery admitted after bridge lease expiry")
	}
	mutationSequence-- // determinate non-admission does not advance source scope
	if !ask(&reconnect).(*application.BridgeResult).Accepted {
		t.Fatal("reconnect did not renew an expired bridge lease")
	}
	if !ask(intent("recovered")).(*application.BridgeIntentResult).Accepted {
		t.Fatal("delivery admission did not recover after reconnect")
	}
	time.Sleep(600 * time.Millisecond)
	ask(&application.PollBridge{SessionID: "session", GenerationID: "generation", Principal: "hosted:source", Handle: attached.Handle, Fence: attached.Fence, MaxItems: 64})
	time.Sleep(600 * time.Millisecond)
	if !ask(intent("poll-heartbeat")).(*application.BridgeIntentResult).Accepted {
		t.Fatal("authenticated poll did not renew bridge lease")
	}
}
