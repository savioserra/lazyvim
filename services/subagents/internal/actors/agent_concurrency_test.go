package actors_test

import (
	"context"
	"crypto/sha256"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
	"github.com/tochemey/goakt/v4/supervisor"
	"github.com/tochemey/goakt/v4/testkit"
)

func TestAgentMailboxOrdersConcurrentSessionsAndPublishesWithoutCustomFanout(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	kit.Spawn(ctx, "agent-registry", actors.NewAgentRegistryActor())
	probe := kit.NewProbe(ctx)
	credential := func(value byte) []byte { return slices.Repeat([]byte{value}, 32) }
	for _, session := range []struct {
		id, generation, caller string
		credential             []byte
	}{
		{"z-session", "z-generation", "z-caller", credential('z')},
		{"a-session", "a-generation", "a-caller", credential('a')},
	} {
		openSession(t, probe, session.id, session.generation, session.caller, session.credential, time.Now().Add(time.Hour))
	}
	if result := coordinateRegistration(t, kit, registration("shared", "observe", "steer"), "register-shared"); !result.Created {
		t.Fatalf("registration failed: %#v", result)
	}

	routeA := authorizedRoute(t, probe, "a-session", "a-generation", "a-caller", credential('a'), "shared", []string{"observe", "steer"})
	routeZ := authorizedRoute(t, probe, "z-session", "z-generation", "z-caller", credential('z'), "shared", []string{"observe", "steer"})
	attach := func(session, generation, principal, handle string) *application.AttachResult {
		value, err := kit.ActorSystem().NoSender().Ask(ctx, routeA.PID, &application.AttachAgent{SessionID: session, GenerationID: generation, Principal: principal, AgentID: "shared", RequestedCapabilities: []string{"observe", "steer"}, IssuedHandle: handle}, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		return value.(*application.AttachResult)
	}
	attachedA := attach("a-session", "a-generation", "a-caller", "handle-a")
	attachedZ := attach("z-session", "z-generation", "z-caller", "handle-z")

	commands := []application.AgentCommand{
		{SessionID: "z-session", GenerationID: "z-generation", Principal: "z-caller", Handle: "handle-z", Fence: attachedZ.Fence, Capability: "steer", Operation: "steer", RequestID: "z-command", PayloadDigest: sha256.Sum256([]byte("z"))},
		{SessionID: "a-session", GenerationID: "a-generation", Principal: "a-caller", Handle: "handle-a", Fence: attachedA.Fence, Capability: "steer", Operation: "steer", RequestID: "a-command", PayloadDigest: sha256.Sum256([]byte("a"))},
	}
	results := make(chan *application.CommandResult, len(commands))
	var group sync.WaitGroup
	for i := range commands {
		group.Add(1)
		go func(command *application.AgentCommand) {
			defer group.Done()
			value, err := kit.ActorSystem().NoSender().Ask(ctx, routeZ.PID, command, time.Second)
			if err != nil {
				t.Errorf("command failed: %v", err)
				return
			}
			results <- value.(*application.CommandResult)
		}(&commands[i])
	}
	group.Wait()
	close(results)
	sequences := make([]uint64, 0, 2)
	for result := range results {
		if !result.Completed || len(result.Subscribers) != 0 {
			t.Fatalf("command exposed a parallel subscriber projection: %#v", result)
		}
		sequences = append(sequences, result.CommandSequence)
	}
	slices.Sort(sequences)
	if !slices.Equal(sequences, []uint64{1, 2}) {
		t.Fatalf("commands were not totally ordered: %v (%s)", sequences, strings.Join([]string{"wanted", "1,2"}, " "))
	}
}

func TestAgentRestartsAfterPanicAndRemainsReachable(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	pid, err := kit.ActorSystem().Spawn(ctx, "panic-agent", &panicActor{}, goakt.WithSupervisor(supervisor.NewSupervisor(supervisor.WithAnyErrorDirective(supervisor.RestartDirective))))
	if err != nil {
		t.Fatal(err)
	}
	probe := kit.NewProbe(ctx)
	probe.Watch(pid)
	probe.Send("panic-agent", "panic")
	probe.ExpectNoMessage()
	if pid.IsSuspended() {
		t.Fatal("restart policy left agent suspended")
	}
	probe.SendSync("panic-agent", "ping", time.Second)
	probe.ExpectMessage("pong")
}

type panicActor struct{}

func (*panicActor) PreStart(*goakt.Context) error { return nil }
func (*panicActor) PostStop(*goakt.Context) error { return nil }
func (*panicActor) Receive(ctx *goakt.ReceiveContext) {
	if ctx.Message() == "panic" {
		panic("forced")
	}
	if ctx.Message() == "ping" {
		ctx.Response("pong")
	}
}

func TestAgentWithoutRestartPolicyStopsOnPanic(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	pid, err := kit.ActorSystem().Spawn(ctx, "suspending-agent", &panicActor{})
	if err != nil {
		t.Fatal(err)
	}
	probe := kit.NewProbe(ctx)
	probe.Watch(pid)
	probe.Send("suspending-agent", "panic")
	probe.ExpectTerminatedWithin("suspending-agent", time.Second)
	if pid.IsSuspended() || pid.IsRunning() {
		t.Fatal("unsupervised panic policy did not stop the actor")
	}
}
