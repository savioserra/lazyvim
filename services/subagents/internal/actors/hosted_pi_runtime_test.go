package actors_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/testkit"
)

type contextAwareHangingRuntime struct {
	started  chan struct{}
	canceled chan struct{}
}

func (r *contextAwareHangingRuntime) Start(ctx context.Context, _ application.HostedPiLaunchSpec) (application.HostedPiOwnedProcess, error) {
	close(r.started)
	<-ctx.Done()
	close(r.canceled)
	return nil, ctx.Err()
}

type blockingHostedRuntime struct {
	process application.HostedPiOwnedProcess
	started chan struct{}
	release chan struct{}
}

func (r *blockingHostedRuntime) Start(context.Context, application.HostedPiLaunchSpec) (application.HostedPiOwnedProcess, error) {
	close(r.started)
	<-r.release
	return r.process, nil
}

type hangingStopProcess struct{ *fakeHostedProcess }

func (p *hangingStopProcess) Stop(ctx context.Context) error { <-ctx.Done(); return ctx.Err() }

type gatedStopProcess struct {
	*fakeHostedProcess
	release chan struct{}
}

func (p *gatedStopProcess) Stop(ctx context.Context) error {
	select {
	case <-p.release:
		p.exited <- nil
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

type fakeHostedRuntime struct {
	process application.HostedPiOwnedProcess
	err     error
}

func (f *fakeHostedRuntime) Start(context.Context, application.HostedPiLaunchSpec) (application.HostedPiOwnedProcess, error) {
	if f.process == nil {
		return nil, f.err
	}
	return f.process, f.err
}

type fakeHostedProcess struct {
	binding application.HostedPiRuntimeBinding
	exited  chan error
	stopped chan struct{}
}

func (f *fakeHostedProcess) Binding() application.HostedPiRuntimeBinding { return f.binding }
func (f *fakeHostedProcess) Wait() error                                 { return <-f.exited }
func (f *fakeHostedProcess) Stop(context.Context) error {
	select {
	case <-f.stopped:
	default:
		close(f.stopped)
		f.exited <- nil
	}
	return nil
}

func TestHostedPiRuntimeActorRunsEffectsAsTypedCompletionsAndReportsDeath(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	owner := kit.NewProbe(ctx)
	binding := application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, RuntimeID: "runtime-one", Incarnation: 1, TmuxSession: "ws-pi-one", TmuxWindow: "pi", TmuxPane: "%1", PanePID: 42, ProcessStartToken: "proof", TTY: "/dev/pts/1"}
	process := &fakeHostedProcess{binding: binding, exited: make(chan error, 1), stopped: make(chan struct{})}
	kit.Spawn(ctx, "hosted-runtime", actors.NewHostedPiRuntimeActor(&fakeHostedRuntime{process: process}, application.HostedPiLaunchSpec{AgentID: "agent-one", RuntimeID: "runtime-one", Incarnation: 1}, owner.PID()))
	pid, err := kit.ActorSystem().ActorOf(ctx, "hosted-runtime")
	if err != nil {
		t.Fatal(err)
	}
	owner.Watch(pid)
	owner.Send(pid.Name(), &application.StartHostedPiRuntime{})
	owner.ExpectMessage(&application.HostedPiRuntimeStateChanged{AgentID: "agent-one", Binding: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, Lifetime: application.HostedPiLifetimeGlobalAgent, TmuxOwnership: application.HostedPiTmuxOwnershipExactSession, ControlBoundary: application.HostedPiControlDocumentedBridgeOnly, VisualizationBoundary: application.HostedPiVisualizationTmuxAttach, RuntimeID: "runtime-one", Incarnation: 1}})
	started := owner.ExpectAnyMessage().(*application.HostedPiRuntimeStateChanged)
	if started.Binding.TmuxPane != "%1" || started.Binding.State != application.HostedPiRuntimeStarting {
		t.Fatalf("unexpected started binding: %#v", started)
	}
	owner.Send(pid.Name(), &application.HostedPiBridgeReadiness{Ready: true})
	ready := owner.ExpectAnyMessage().(*application.HostedPiRuntimeStateChanged)
	if ready.Binding.State != application.HostedPiRuntimeReady || !ready.Binding.BridgeReady {
		t.Fatalf("runtime did not become ready: %#v", ready)
	}
	owner.Send(pid.Name(), &application.StopHostedPiRuntime{Reason: "test"})
	stopping := owner.ExpectAnyMessage().(*application.HostedPiRuntimeStateChanged)
	if stopping.Binding.State != application.HostedPiRuntimeStopping {
		t.Fatalf("runtime did not enter stopping: %#v", stopping)
	}
	select {
	case <-process.stopped:
	case <-time.After(time.Second):
		t.Fatal("asynchronous stop effect did not run")
	}
	stopped := owner.ExpectAnyMessage().(*application.HostedPiRuntimeStateChanged)
	if stopped.Binding.State != application.HostedPiRuntimeStopped {
		t.Fatalf("runtime death was not reported: %#v", stopped)
	}
	if err := pid.Shutdown(ctx); err != nil {
		t.Fatal(err)
	}
	owner.ExpectTerminatedWithin(pid.Name(), time.Second)
}

func TestHostedPiRuntimeActorRejectsReadinessRevivalDuringStop(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	owner := kit.NewProbe(ctx)
	base := &fakeHostedProcess{binding: application.HostedPiRuntimeBinding{RuntimeID: "stop-fence", Incarnation: 1}, exited: make(chan error, 1), stopped: make(chan struct{})}
	process := &gatedStopProcess{fakeHostedProcess: base, release: make(chan struct{})}
	kit.Spawn(ctx, "hosted-runtime-stop-fence", actors.NewHostedPiRuntimeActor(&fakeHostedRuntime{process: process}, application.HostedPiLaunchSpec{AgentID: "stop-fence", RuntimeID: "stop-fence", Incarnation: 1}, owner.PID()))
	pid, _ := kit.ActorSystem().ActorOf(ctx, "hosted-runtime-stop-fence")
	owner.Send(pid.Name(), &application.StartHostedPiRuntime{})
	owner.ExpectAnyMessage()
	owner.ExpectAnyMessage()
	owner.Send(pid.Name(), &application.HostedPiBridgeReadiness{Ready: true})
	owner.ExpectAnyMessage()
	accepted := make(chan application.OperationResult, 1)
	owner.Send(pid.Name(), &application.StopHostedPiRuntime{Reason: "test", Accepted: accepted})
	stopping := owner.ExpectAnyMessage().(*application.HostedPiRuntimeStateChanged)
	if stopping.Binding.State != application.HostedPiRuntimeStopping {
		t.Fatalf("runtime did not enter stopping: %#v", stopping)
	}
	if result := <-accepted; !result.Completed {
		t.Fatalf("stop was not admitted: %#v", result)
	}
	owner.Send(pid.Name(), &application.HostedPiBridgeReadiness{Ready: true})
	value, err := kit.ActorSystem().NoSender().Ask(ctx, pid, &application.HostedPiRuntimeStatus{}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	status := value.(*application.HostedPiRuntimeBinding)
	if status.State != application.HostedPiRuntimeStopping || status.BridgeReady {
		t.Fatalf("readiness revived stopping runtime: %#v", status)
	}
	close(process.release)
	stopped := owner.ExpectAnyMessage().(*application.HostedPiRuntimeStateChanged)
	if stopped.Binding.State != application.HostedPiRuntimeStopped {
		t.Fatalf("runtime did not finish exact stop: %#v", stopped)
	}
}

func TestHostedPiRuntimeActorTreatsUnrequestedLossAsDegraded(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	owner := kit.NewProbe(ctx)
	process := &fakeHostedProcess{binding: application.HostedPiRuntimeBinding{RuntimeID: "lost", Incarnation: 1}, exited: make(chan error, 1), stopped: make(chan struct{})}
	kit.Spawn(ctx, "hosted-runtime-lost", actors.NewHostedPiRuntimeActor(&fakeHostedRuntime{process: process}, application.HostedPiLaunchSpec{AgentID: "lost", RuntimeID: "lost", Incarnation: 1}, owner.PID()))
	pid, _ := kit.ActorSystem().ActorOf(ctx, "hosted-runtime-lost")
	owner.Send(pid.Name(), &application.StartHostedPiRuntime{})
	owner.ExpectAnyMessage()
	owner.ExpectAnyMessage()
	process.exited <- nil
	lost := owner.ExpectAnyMessage().(*application.HostedPiRuntimeStateChanged)
	if lost.Binding.State != application.HostedPiRuntimeDegraded {
		t.Fatalf("unexpected loss claimed stopped: %#v", lost)
	}
}

func TestHostedPiRuntimeActorMergesReadinessObservedBeforeStartCompletion(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	owner := kit.NewProbe(ctx)
	binding := application.HostedPiRuntimeBinding{RuntimeID: "runtime-race", Incarnation: 1, TmuxPane: "%9"}
	process := &fakeHostedProcess{binding: binding, exited: make(chan error, 1), stopped: make(chan struct{})}
	runtime := &blockingHostedRuntime{process: process, started: make(chan struct{}), release: make(chan struct{})}
	kit.Spawn(ctx, "hosted-runtime-race", actors.NewHostedPiRuntimeActor(runtime, application.HostedPiLaunchSpec{AgentID: "agent-race", RuntimeID: "runtime-race", Incarnation: 1}, owner.PID()))
	pid, err := kit.ActorSystem().ActorOf(ctx, "hosted-runtime-race")
	if err != nil {
		t.Fatal(err)
	}
	owner.Send(pid.Name(), &application.StartHostedPiRuntime{})
	owner.ExpectAnyMessage()
	<-runtime.started
	owner.Send(pid.Name(), &application.HostedPiBridgeReadiness{Ready: true})
	early := owner.ExpectAnyMessage().(*application.HostedPiRuntimeStateChanged)
	if !early.Binding.BridgeReady {
		t.Fatal("early readiness was not observed")
	}
	close(runtime.release)
	merged := owner.ExpectAnyMessage().(*application.HostedPiRuntimeStateChanged)
	if !merged.Binding.BridgeReady || merged.Binding.State != application.HostedPiRuntimeReady || merged.Binding.TmuxPane != "%9" {
		t.Fatalf("start completion lost readiness: %#v", merged)
	}
}

func TestHostedPiRuntimeActorCancelsHangingStartOnStop(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	owner := kit.NewProbe(ctx)
	runtime := &contextAwareHangingRuntime{started: make(chan struct{}), canceled: make(chan struct{})}
	kit.Spawn(ctx, "hosted-runtime-hanging-start", actors.NewHostedPiRuntimeActor(runtime, application.HostedPiLaunchSpec{AgentID: "hang-start", RuntimeID: "hang-start", Incarnation: 1}, owner.PID()))
	pid, _ := kit.ActorSystem().ActorOf(ctx, "hosted-runtime-hanging-start")
	owner.Send(pid.Name(), &application.StartHostedPiRuntime{Timeout: time.Minute})
	owner.ExpectAnyMessage()
	<-runtime.started
	owner.Send(pid.Name(), &application.StopHostedPiRuntime{Reason: "cancel start", Timeout: time.Second})
	owner.ExpectAnyMessage()
	select {
	case <-runtime.canceled:
	case <-time.After(time.Second):
		t.Fatal("stop did not cancel actor-managed start context")
	}
	stopped := owner.ExpectAnyMessage().(*application.HostedPiRuntimeStateChanged)
	if stopped.Binding.State != application.HostedPiRuntimeStopped {
		t.Fatalf("canceled start without an owned process did not settle stopped: %#v", stopped)
	}
}

func TestHostedPiRuntimeActorBoundsHangingStop(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	owner := kit.NewProbe(ctx)
	process := &hangingStopProcess{&fakeHostedProcess{binding: application.HostedPiRuntimeBinding{RuntimeID: "hang", Incarnation: 1}, exited: make(chan error, 1), stopped: make(chan struct{})}}
	kit.Spawn(ctx, "hosted-runtime-hang", actors.NewHostedPiRuntimeActor(&fakeHostedRuntime{process: process}, application.HostedPiLaunchSpec{AgentID: "hang", RuntimeID: "hang", Incarnation: 1}, owner.PID()))
	pid, _ := kit.ActorSystem().ActorOf(ctx, "hosted-runtime-hang")
	owner.Send(pid.Name(), &application.StartHostedPiRuntime{})
	owner.ExpectAnyMessage()
	owner.ExpectAnyMessage()
	owner.Send(pid.Name(), &application.StopHostedPiRuntime{Reason: "test cancellation", Timeout: 20 * time.Millisecond})
	owner.ExpectAnyMessage()
	degraded := owner.ExpectAnyMessage().(*application.HostedPiRuntimeStateChanged)
	if degraded.Binding.State != application.HostedPiRuntimeDegraded {
		t.Fatalf("hanging stop was not bounded: %#v", degraded)
	}
}

func TestHostedPiRuntimeActorFailsClosedOnStartError(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	owner := kit.NewProbe(ctx)
	kit.Spawn(ctx, "failed-hosted-runtime", actors.NewHostedPiRuntimeActor(&fakeHostedRuntime{err: errors.New("boom")}, application.HostedPiLaunchSpec{AgentID: "agent", RuntimeID: "runtime", Incarnation: 1}, owner.PID()))
	pid, err := kit.ActorSystem().ActorOf(ctx, "failed-hosted-runtime")
	if err != nil {
		t.Fatal(err)
	}
	owner.Send(pid.Name(), &application.StartHostedPiRuntime{})
	owner.ExpectAnyMessage()
	failed := owner.ExpectAnyMessage().(*application.HostedPiRuntimeStateChanged)
	if failed.Binding.State != application.HostedPiRuntimeDegraded {
		t.Fatalf("start failure was not degraded: %#v", failed)
	}
}
