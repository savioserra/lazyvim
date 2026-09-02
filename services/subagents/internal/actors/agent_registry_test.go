package actors_test

import (
	"context"
	"crypto/sha256"
	"fmt"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
	"github.com/tochemey/goakt/v4/testkit"
)

func registration(agentID string, capabilities ...string) application.RegisterAgent {
	return application.RegisterAgent{
		AgentID: agentID, AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "upstream-run"},
		HostedPiRuntime: application.InactiveHostedPiRuntimeBinding(), AllowedCapability: capabilities, Retention: "explicit", Recovery: "metadata-only",
	}
}

func coordinateRegistration(t *testing.T, kit *testkit.TestKit, value application.RegisterAgent, operation string) application.RegisterAgentResult {
	t.Helper()
	result := make(chan application.RegisterAgentResult, 1)
	if err := kit.ActorSystem().NoSender().Tell(context.Background(), mustActor(t, kit, "agent-registry"), &application.CoordinateAgentRegistration{OperationID: operation, Registration: value, Result: result}); err != nil {
		t.Fatal(err)
	}
	select {
	case response := <-result:
		return response
	case <-time.After(time.Second):
		t.Fatal("registration result timed out")
		return application.RegisterAgentResult{}
	}
}
func mustActor(t *testing.T, kit *testkit.TestKit, name string) *actor.PID {
	t.Helper()
	pid, err := kit.ActorSystem().ActorOf(context.Background(), name)
	if err != nil {
		t.Fatal(err)
	}
	return pid
}

func TestAgentRegistryPublishesValidatedDisplayMetadata(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	kit.Spawn(ctx, "agent-registry", actors.NewAgentRegistryActor())
	cases := []struct{ id, requestedRole, requestedName, role, displayName string }{{"alpha-worker", "Code Reviewer", "Worker One", "Code Reviewer", "Worker One"}, {"beta", "QA", "Reviewer Two", "QA", "Reviewer Two"}, {"gamma", "", "", "", "gamma"}}
	for _, item := range cases {
		registration := registration(item.id, "observe")
		registration.Role = item.requestedRole
		registration.DisplayName = item.requestedName
		if result := coordinateRegistration(t, kit, registration, "register-"+item.id); !result.Created {
			t.Fatalf("registration failed: %#v", result)
		}
		value, err := kit.ActorSystem().NoSender().Ask(ctx, mustActor(t, kit, "agent-registry"), &application.ResolveAgentControl{AgentID: item.id}, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		resolved := value.(*application.AgentControlPID)
		if !resolved.Found || resolved.Reference.Role != item.role || resolved.Reference.DisplayName != item.displayName {
			t.Fatalf("aggregate metadata was not server authoritative: %#v", resolved.Reference)
		}
	}
}

func openSession(t *testing.T, probe testkit.Probe, id, generation, caller string, credential []byte, expires time.Time) {
	t.Helper()
	session := application.OpenSession{SessionID: id, GenerationID: generation, Caller: caller, Credential: credential, Capabilities: []string{"observe", "steer"}, ExpiresAt: expires}
	probe.Send("agent-registry", &application.StageSession{Session: session, Registry: application.AgentRegistry, Acknowledge: probe.PID()})
	probe.ExpectMessage(&application.SessionStageAck{SessionID: id, GenerationID: generation, Registry: application.AgentRegistry, Accepted: true})
}

func TestCloseCompletesCleanupRejectsLateGenerationAndPreservesAgent(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	kit.Spawn(ctx, "agent-registry", actors.NewAgentRegistryActor())
	probe := kit.NewProbe(ctx)
	credentialOne := []byte(strings.Repeat("1", 32))
	credentialTwo := []byte(strings.Repeat("2", 32))
	if result := coordinateRegistration(t, kit, registration("stable-agent", "observe", "steer"), "register-stable"); !result.Created {
		t.Fatalf("registration failed: %#v", result)
	}
	openSession(t, probe, "session", "generation-one", "caller-one", credentialOne, time.Now().Add(time.Hour))
	routeOne := authorizedRoute(t, probe, "session", "generation-one", "caller-one", credentialOne, "stable-agent", []string{"observe", "steer"})
	attached := askAttach(t, kit, routeOne, "session", "generation-one", "caller-one", "handle-one")
	value, err := kit.ActorSystem().NoSender().Ask(ctx, routeOne.PID, &application.ReattachAgent{SessionID: "session", GenerationID: "generation-one", Principal: "caller-one", PreviousHandle: "wrong", PreviousFence: attached.Fence, IssuedHandle: "rejected"}, time.Second)
	if err != nil || value.(*application.AttachResult).Completed {
		t.Fatalf("stale reattach fence accepted: %#v %v", value, err)
	}
	value, err = kit.ActorSystem().NoSender().Ask(ctx, routeOne.PID, &application.ReattachAgent{SessionID: "session", GenerationID: "generation-one", Principal: "caller-one", PreviousHandle: attached.Handle, PreviousFence: attached.Fence, IssuedHandle: "handle-rotated"}, time.Second)
	if err != nil || !value.(*application.AttachResult).Completed {
		t.Fatalf("valid reattach failed: %#v %v", value, err)
	}
	rotated := value.(*application.AttachResult)
	value, err = kit.ActorSystem().NoSender().Ask(ctx, routeOne.PID, &application.SubscribeAgent{SessionID: "session", GenerationID: "generation-one", Principal: "caller-one", Handle: attached.Handle, Fence: attached.Fence}, time.Second)
	if err != nil || value.(*application.OperationResult).Completed {
		t.Fatalf("old fence remained authorized: %#v %v", value, err)
	}
	probe.Watch(routeOne.PID)
	closeAgentSession(t, kit, probe, "session", "generation-one")
	probe.ExpectNoMessage()
	value, err = kit.ActorSystem().NoSender().Ask(ctx, routeOne.PID, &application.Subscribers{}, time.Second)
	if err != nil || len(value.(*application.SubscriberList).SessionIDs) != 0 {
		t.Fatalf("close acknowledged before cleanup: %#v %v", value, err)
	}
	late := askAttach(t, kit, routeOne, "session", "generation-one", "caller-one", "late-handle")
	if late.Completed || !strings.Contains(late.Reason, "revoked") {
		t.Fatalf("late attach recreated closed generation: %#v", late)
	}
	value, err = kit.ActorSystem().NoSender().Ask(ctx, routeOne.PID, &application.SubscribeAgent{SessionID: "session", GenerationID: "generation-one", Principal: "caller-one", Handle: rotated.Handle, Fence: rotated.Fence}, time.Second)
	if err != nil || value.(*application.OperationResult).Completed {
		t.Fatalf("late subscribe recreated closed generation: %#v %v", value, err)
	}
	value, err = kit.ActorSystem().NoSender().Ask(ctx, routeOne.PID, &application.AgentCommand{SessionID: "session", GenerationID: "generation-one", Principal: "caller-one", Handle: rotated.Handle, Fence: rotated.Fence, Capability: "steer", Operation: "steer", RequestID: "late-command", PayloadDigest: sha256.Sum256([]byte("late"))}, time.Second)
	if err != nil || value.(*application.CommandResult).Completed {
		t.Fatalf("late command executed for closed generation: %#v %v", value, err)
	}

	openSession(t, probe, "session", "generation-two", "caller-two", credentialTwo, time.Now().Add(time.Hour))
	probe.SendSync("agent-registry", &application.ResolveAgent{SessionID: "session", GenerationID: "generation-two", Caller: "caller-two", Credential: credentialTwo, AgentID: "stable-agent"}, time.Second)
	if resolved := probe.ExpectAnyMessage().(*application.ResolveAgentResult); !resolved.Found {
		t.Fatalf("agent did not survive cleanup: %#v", resolved)
	}
	routeTwo := authorizedRoute(t, probe, "session", "generation-two", "caller-two", credentialTwo, "stable-agent", []string{"observe", "steer"})
	second := askAttach(t, kit, routeTwo, "session", "generation-two", "caller-two", "handle-two")
	if !second.Completed || second.Fence <= rotated.Fence {
		t.Fatalf("later generation did not reuse agent: %#v", second)
	}
}

func TestCommandDedupeAuthenticatesPrincipalGenerationAndDigest(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	kit.Spawn(ctx, "agent-registry", actors.NewAgentRegistryActor())
	probe := kit.NewProbe(ctx)
	one := []byte(strings.Repeat("a", 32))
	two := []byte(strings.Repeat("b", 32))
	openSession(t, probe, "one", "g-one", "caller-one", one, time.Now().Add(time.Hour))
	openSession(t, probe, "two", "g-two", "caller-two", two, time.Now().Add(time.Hour))
	if result := coordinateRegistration(t, kit, registration("agent", "observe", "steer"), "register-agent"); !result.Created {
		t.Fatalf("registration failed: %#v", result)
	}
	routeOne := authorizedRoute(t, probe, "one", "g-one", "caller-one", one, "agent", []string{"observe", "steer"})
	routeTwo := authorizedRoute(t, probe, "two", "g-two", "caller-two", two, "agent", []string{"observe", "steer"})
	firstAttach := askAttach(t, kit, routeOne, "one", "g-one", "caller-one", "one-handle")
	secondAttach := askAttach(t, kit, routeTwo, "two", "g-two", "caller-two", "two-handle")
	digest := sha256.Sum256([]byte("payload-one"))
	command := func(route *application.AgentRoute, session, generation, principal, handle string, fence uint64, payload [32]byte) *application.CommandResult {
		value, err := kit.ActorSystem().NoSender().Ask(ctx, route.PID, &application.AgentCommand{SessionID: session, GenerationID: generation, Principal: principal, Handle: handle, Fence: fence, Capability: "steer", Operation: "steer", RequestID: "same-id", PayloadDigest: payload}, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		return value.(*application.CommandResult)
	}
	first := command(routeOne, "one", "g-one", "caller-one", firstAttach.Handle, firstAttach.Fence, digest)
	repeated := command(routeOne, "one", "g-one", "caller-one", firstAttach.Handle, firstAttach.Fence, digest)
	if !first.Completed || repeated.CommandSequence != first.CommandSequence {
		t.Fatalf("same request did not dedupe: first=%#v repeated=%#v", first, repeated)
	}
	collision := command(routeOne, "one", "g-one", "caller-one", firstAttach.Handle, firstAttach.Fence, sha256.Sum256([]byte("other")))
	if collision.Completed || !strings.Contains(collision.Reason, "collision") {
		t.Fatalf("digest collision accepted: %#v", collision)
	}
	crossSession := command(routeTwo, "two", "g-two", "caller-two", secondAttach.Handle, secondAttach.Fence, digest)
	if !crossSession.Completed || crossSession.CommandSequence == first.CommandSequence {
		t.Fatalf("cross-session request ID collided: %#v", crossSession)
	}
	for index := 0; index < 1024; index++ {
		value, askErr := kit.ActorSystem().NoSender().Ask(ctx, routeOne.PID, &application.AgentCommand{SessionID: "one", GenerationID: "g-one", Principal: "caller-one", Handle: firstAttach.Handle, Fence: firstAttach.Fence, Capability: "steer", Operation: "steer", RequestID: fmt.Sprintf("evict-%d", index), PayloadDigest: sha256.Sum256([]byte(fmt.Sprintf("payload-%d", index)))}, time.Second)
		if askErr != nil || !value.(*application.CommandResult).Completed {
			t.Fatalf("fill command %d failed: %#v %v", index, value, askErr)
		}
	}
	forgotten := command(routeOne, "one", "g-one", "caller-one", firstAttach.Handle, firstAttach.Fence, digest)
	if forgotten.Completed || !strings.Contains(forgotten.Reason, "outside the retained") {
		t.Fatalf("evicted command executed again: %#v", forgotten)
	}
	closeAgentSession(t, kit, probe, "one", "g-one")
	stale := command(routeOne, "one", "g-one", "caller-one", firstAttach.Handle, firstAttach.Fence, digest)
	if stale.Completed || !strings.Contains(stale.Reason, "stale") {
		t.Fatalf("stale handle obtained cached result: %#v", stale)
	}
}

func TestRegistrationRejectsPhaseTwoAndNonTypedAuthority(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	kit.Spawn(ctx, "agent-registry", actors.NewAgentRegistryActor())
	owned := registration("owned", "observe")
	owned.PhaseTwoOwned = true
	if result := coordinateRegistration(t, kit, owned, "invalid-owned"); result.Created {
		t.Fatalf("invalid owned registration accepted: %#v", result)
	}
	untyped := registration("untyped", "observe")
	untyped.AuthorityBinding = application.AuthorityBinding{}
	if result := coordinateRegistration(t, kit, untyped, "invalid-untyped"); result.Created {
		t.Fatalf("untyped registration accepted: %#v", result)
	}
}

func closeAgentSession(t *testing.T, kit *testkit.TestKit, probe testkit.Probe, session, generation string) {
	t.Helper()
	probe.Send("agent-registry", &application.PrepareSessionClose{SessionID: session, GenerationID: generation, Registry: application.AgentRegistry, Acknowledge: probe.PID()})
	plan := probe.ExpectAnyMessage().(*application.SessionPrepareAck)
	for _, name := range plan.AgentNames {
		agent, err := kit.ActorSystem().ActorOf(context.Background(), name)
		if err != nil {
			t.Fatal(err)
		}
		result := make(chan application.OperationResult, 1)
		if err := kit.ActorSystem().NoSender().Tell(context.Background(), agent, &application.DropSession{SessionID: session, GenerationID: generation, Result: result}); err != nil {
			t.Fatal(err)
		}
		select {
		case value := <-result:
			if !value.Completed {
				t.Fatalf("agent cleanup failed: %#v", value)
			}
		case <-time.After(time.Second):
			t.Fatal("agent cleanup timed out")
		}
	}
	probe.Send("agent-registry", &application.CommitSessionClose{SessionID: session, GenerationID: generation, Registry: application.AgentRegistry, Acknowledge: probe.PID()})
	probe.ExpectMessage(&application.SessionCommitAck{SessionID: session, GenerationID: generation, Registry: application.AgentRegistry})
}

func authorizedRoute(t *testing.T, probe testkit.Probe, session, generation, caller string, credential []byte, agentID string, capabilities []string) *application.AgentRoute {
	t.Helper()
	probe.SendSync("agent-registry", &application.AuthorizeAgentAccess{SessionID: session, GenerationID: generation, Caller: caller, Credential: credential, AgentID: agentID, Capabilities: capabilities}, time.Second)
	route := probe.ExpectAnyMessage().(*application.AgentRoute)
	if !route.Allowed || route.PID == nil {
		t.Fatalf("authorization failed: %#v", route)
	}
	return route
}

func askAttach(t *testing.T, kit *testkit.TestKit, route *application.AgentRoute, session, generation, principal, handle string) *application.AttachResult {
	t.Helper()
	value, err := kit.ActorSystem().NoSender().Ask(context.Background(), route.PID, &application.AttachAgent{SessionID: session, GenerationID: generation, Principal: principal, AgentID: "agent", RequestedCapabilities: []string{"observe", "steer"}, IssuedHandle: handle}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	return value.(*application.AttachResult)
}

func ptr[T any](value T) *T { return &value }

type registryProcess struct {
	binding application.HostedPiRuntimeBinding
	wait    chan struct{}
}

func (p *registryProcess) Binding() application.HostedPiRuntimeBinding { return p.binding }
func (p *registryProcess) Wait() error {
	<-p.wait
	return nil
}
func (*registryProcess) Stop(context.Context) error { return nil }

type registryRuntime struct {
	starts int32
	proc   *registryProcess
}

func (r *registryRuntime) Start(context.Context, application.HostedPiLaunchSpec) (application.HostedPiOwnedProcess, error) {
	atomic.AddInt32(&r.starts, 1)
	return r.proc, nil
}

func hostedRegistration(agentID string, runtime *registryRuntime) application.RegisterAgent {
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.State = application.HostedPiRuntimeStarting
	binding.RuntimeID = "runtime-" + agentID
	binding.Incarnation = 1
	binding.Lifetime = application.HostedPiLifetimeGlobalAgent
	binding.TmuxOwnership = application.HostedPiTmuxOwnershipExactSession
	binding.ControlBoundary = application.HostedPiControlDocumentedBridgeOnly
	binding.VisualizationBoundary = application.HostedPiVisualizationTmuxAttach
	runtime.proc.binding = binding
	runtime.proc.binding.TmuxSessionID = "tmux-" + agentID
	runtime.proc.binding.TmuxSession = "tmux-" + agentID
	spec := application.HostedPiLaunchSpec{AgentID: agentID, RuntimeID: binding.RuntimeID, Incarnation: 1, TmuxSession: "tmux-" + agentID, TmuxWindow: "pi", PiSessionDirectory: "/tmp/" + agentID, PiSessionName: "pi-" + agentID}
	record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: agentID, AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: binding.RuntimeID}, AllowedCapabilities: []string{"observe", "steer", "hosted_bridge"}, Retention: "explicit", Recovery: "owned-binding-v2", LaunchSpec: spec, Binding: binding}
	return application.RegisterAgent{AgentID: agentID, AuthorityBinding: record.AuthorityBinding, HostedPiRuntime: binding, AllowedCapability: append([]string(nil), record.AllowedCapabilities...), PhaseTwoOwned: true, Retention: record.Retention, Recovery: record.Recovery, Runtime: runtime, LaunchSpec: spec, RuntimeStartTimeout: time.Second, DurableRecord: &record}
}

func TestHostedRegistryReconcilesTerminatedGlobalAgentsWithoutDuplicatingRuntime(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	kit.Spawn(ctx, "agent-registry", actors.NewAgentRegistryActor())
	probe := kit.NewProbe(ctx)
	credential := []byte(strings.Repeat("h", 32))
	openSession(t, probe, "client", "generation-0", "caller", credential, time.Now().Add(time.Hour))
	runtimes := map[string]*registryRuntime{}
	for _, agentID := range []string{"hosted-one", "hosted-two"} {
		runtime := &registryRuntime{proc: &registryProcess{wait: make(chan struct{})}}
		runtimes[agentID] = runtime
		if result := coordinateRegistration(t, kit, hostedRegistration(agentID, runtime), "register-"+agentID); !result.Created {
			t.Fatalf("hosted registration %s failed: %#v", agentID, result)
		}
	}
	for cycle := 1; cycle <= 4; cycle++ {
		for _, agentID := range []string{"hosted-one", "hosted-two"} {
			route := authorizedRoute(t, probe, "client", fmt.Sprintf("generation-%d", cycle-1), "caller", credential, agentID, []string{"observe", "steer"})
			attached := askAttachForAgent(t, kit, route, agentID, "client", fmt.Sprintf("generation-%d", cycle-1), "caller", fmt.Sprintf("handle-%s-%d", agentID, cycle))
			if !attached.Completed {
				t.Fatalf("attach failed for %s cycle %d: %#v", agentID, cycle, attached)
			}
			if cycle == 1 {
				if err := route.PID.Shutdown(ctx); err != nil {
					t.Fatalf("shutdown %s to force GoAkt Terminated path: %v", agentID, err)
				}
				resolved := waitHostedControl(t, kit, agentID)
				if resolved.PID == nil || resolved.PID.Name() != route.PID.Name() {
					t.Fatalf("registry did not recreate stable actor name for %s: %#v", agentID, resolved)
				}
			}
		}
		closeAgentSession(t, kit, probe, "client", fmt.Sprintf("generation-%d", cycle-1))
		if cycle < 4 {
			openSession(t, probe, "client", fmt.Sprintf("generation-%d", cycle), "caller", credential, time.Now().Add(time.Hour))
		}
	}
	for agentID, runtime := range runtimes {
		if starts := atomic.LoadInt32(&runtime.starts); starts != 1 {
			t.Fatalf("hosted runtime %s started %d times; registry duplicated the hosted tmux runtime", agentID, starts)
		}
		resolved := waitHostedControl(t, kit, agentID)
		if !resolved.Found || resolved.PID == nil {
			t.Fatalf("hosted actor %s not resolvable after client cycles: %#v", agentID, resolved)
		}
	}
}

func waitHostedControl(t *testing.T, kit *testkit.TestKit, agentID string) *application.AgentControlPID {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for {
		value, err := kit.ActorSystem().NoSender().Ask(context.Background(), mustActor(t, kit, "agent-registry"), &application.ResolveAgentControl{AgentID: agentID}, time.Second)
		if err == nil {
			resolved := value.(*application.AgentControlPID)
			if resolved.Found && resolved.PID != nil {
				return resolved
			}
		}
		if time.Now().After(deadline) {
			if err != nil {
				t.Fatal(err)
			}
			return &application.AgentControlPID{}
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func askAttachForAgent(t *testing.T, kit *testkit.TestKit, route *application.AgentRoute, agentID, session, generation, principal, handle string) *application.AttachResult {
	t.Helper()
	value, err := kit.ActorSystem().NoSender().Ask(context.Background(), route.PID, &application.AttachAgent{SessionID: session, GenerationID: generation, Principal: principal, AgentID: agentID, RequestedCapabilities: []string{"observe", "steer"}, IssuedHandle: handle}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	return value.(*application.AttachResult)
}
