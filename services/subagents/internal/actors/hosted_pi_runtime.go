package actors

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

// HostedPiRuntimeActor serializes lifecycle state while all subprocess, tmux,
// and filesystem effects execute outside Receive and report typed completions.
const maxHostedRuntimeRecoveryAttempts = 3

var hostedRuntimeRecoveryDelays = [...]time.Duration{250 * time.Millisecond, time.Second, 4 * time.Second}

type HostedPiRuntimeActor struct {
	runtime          application.HostedPiRuntime
	spec             application.HostedPiLaunchSpec
	owner            *actor.PID
	process          application.HostedPiOwnedProcess
	binding          application.HostedPiRuntimeBinding
	busy             bool
	pendingStop      bool
	cleanupFailed    bool
	exitObserved     bool
	stopSucceeded    bool
	startCancel      context.CancelFunc
	adoptObserved    bool
	lastFailure      string
	recoveryToken    uint64
	recoveryAttempts uint8
}

func NewHostedPiRuntimeActor(runtime application.HostedPiRuntime, spec application.HostedPiLaunchSpec, owner *actor.PID, adopted ...application.HostedPiOwnedProcess) *HostedPiRuntimeActor {
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.RuntimeID = spec.RuntimeID
	binding.Incarnation = spec.Incarnation
	value := &HostedPiRuntimeActor{runtime: runtime, spec: spec, owner: owner, binding: binding}
	if len(adopted) > 0 && adopted[0] != nil {
		value.process = adopted[0]
		value.binding = adopted[0].Binding()
	}
	return value
}

func (a *HostedPiRuntimeActor) PreStart(*actor.Context) error { return nil }
func (a *HostedPiRuntimeActor) PostStop(*actor.Context) error {
	if a.startCancel != nil {
		a.startCancel()
		a.startCancel = nil
	}
	return nil
}

func (a *HostedPiRuntimeActor) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *application.StartHostedPiRuntime:
		a.start(ctx, message)
	case *application.RetryHostedPiRuntime:
		a.retry(ctx, message)
	case *application.HostedPiRuntimeStarted:
		a.started(ctx, message)
	case *application.HostedPiRuntimeExited:
		a.exited(ctx, message)
	case *application.StopHostedPiRuntime:
		a.stop(ctx, message)
	case *application.RebindHostedPiRuntimeOwner:
		a.owner = message.PID
		a.changed(ctx, "")
	case *application.HostedPiRuntimeStoppedResult:
		a.stopped(ctx, message)
	case *application.HostedPiBridgeReadiness:
		if a.binding.State == application.HostedPiRuntimeStopping || a.binding.State == application.HostedPiRuntimeStopped {
			a.binding.BridgeReady = false
			return
		}
		a.binding.BridgeReady = message.Ready
		if message.Ready && a.process != nil {
			a.binding.State = application.HostedPiRuntimeReady
		} else if a.process != nil {
			a.binding.State = application.HostedPiRuntimeStarting
		}
		a.changed(ctx, "")
		if message.Ready {
			a.recoveryAttempts = 0
		}
	case *application.HostedPiRuntimeStatus:
		copy := a.binding
		ctx.Response(&copy)
	case *application.HostedPiRuntimeFailureStatus:
		ctx.Response(&application.HostedPiRuntimeFailure{Reason: a.lastFailure})
	default:
		ctx.Unhandled()
	}
}

func (a *HostedPiRuntimeActor) start(ctx *actor.ReceiveContext, message *application.StartHostedPiRuntime) {
	if a.process != nil {
		a.changed(ctx, "")
		if !a.adoptObserved {
			a.adoptObserved = true
			process, self, system := a.process, ctx.Self(), ctx.ActorSystem()
			go func() {
				_ = system.NoSender().Tell(context.Background(), self, &application.HostedPiRuntimeExited{Err: process.Wait()})
			}()
		}
		return
	}
	if a.busy || a.runtime == nil {
		return
	}
	a.busy = true
	a.binding.State = application.HostedPiRuntimeStarting
	a.log(ctx, "start_requested", "none")
	a.changed(ctx, "")
	system, self := ctx.ActorSystem(), ctx.Self()
	runtime, spec, fallback := a.runtime, a.spec, a.binding
	timeout := message.Timeout
	if timeout <= 0 || timeout > 30*time.Second {
		timeout = 10 * time.Second
	}
	startCtx, cancel := context.WithTimeout(context.Background(), timeout)
	a.startCancel = cancel
	go func() {
		process, err := runtime.Start(startCtx, spec)
		binding := fallback
		if process != nil {
			binding = process.Binding()
		}
		_ = system.NoSender().Tell(context.Background(), self, &application.HostedPiRuntimeStarted{Process: process, Binding: binding, Err: err})
	}()
}

func (a *HostedPiRuntimeActor) started(ctx *actor.ReceiveContext, message *application.HostedPiRuntimeStarted) {
	if a.startCancel != nil {
		a.startCancel()
		a.startCancel = nil
	}
	a.busy = false
	if message.Err != nil || message.Process == nil {
		if a.pendingStop && !errors.Is(message.Err, application.ErrHostedOwnershipIndeterminate) {
			a.pendingStop = false
			a.binding.State = application.HostedPiRuntimeStopped
			a.changed(ctx, "")
			return
		}
		a.binding.State = application.HostedPiRuntimeDegraded
		a.binding.OwnershipIndeterminate = errors.Is(message.Err, application.ErrHostedOwnershipIndeterminate)
		a.lastFailure = boundedRuntimeFailure(message.Err)
		a.log(ctx, "start_failed", runtimeFailureClass(message.Err))
		a.changed(ctx, "runtime start failed")
		if a.recoveryAttempts > 0 && !a.binding.OwnershipIndeterminate {
			a.scheduleRecovery(ctx)
		}
		return
	}
	a.process = message.Process
	a.lastFailure = ""
	a.log(ctx, "start_succeeded", "none")
	ready := a.binding.BridgeReady
	a.binding = message.Binding
	a.binding.RuntimeID, a.binding.Incarnation = a.spec.RuntimeID, a.spec.Incarnation
	a.binding.BridgeReady = ready
	if ready {
		a.binding.State = application.HostedPiRuntimeReady
	} else {
		a.binding.State = application.HostedPiRuntimeStarting
	}
	a.changed(ctx, "")
	if a.pendingStop {
		a.pendingStop = false
		a.stop(ctx, &application.StopHostedPiRuntime{Reason: "stop requested during start"})
	}
	system, self, process := ctx.ActorSystem(), ctx.Self(), a.process
	go func() {
		err := process.Wait()
		_ = system.NoSender().Tell(context.Background(), self, &application.HostedPiRuntimeExited{Err: err})
	}()
}

func (a *HostedPiRuntimeActor) exited(ctx *actor.ReceiveContext, message *application.HostedPiRuntimeExited) {
	if a.process == nil && !a.exitObserved {
		return
	}
	a.process = nil
	a.exitObserved = true
	a.binding.BridgeReady = false
	if a.binding.State == application.HostedPiRuntimeStopping {
		if a.cleanupFailed {
			a.binding.State = application.HostedPiRuntimeDegraded
			a.changed(ctx, "runtime cleanup failed")
		} else if a.stopSucceeded {
			a.binding.State = application.HostedPiRuntimeStopped
			a.changed(ctx, "")
		}
		return
	}
	a.busy = false
	a.lastFailure = boundedRuntimeFailure(message.Err)
	a.binding.OwnershipIndeterminate = errors.Is(message.Err, application.ErrHostedOwnershipIndeterminate)
	a.binding.State = application.HostedPiRuntimeDegraded
	a.logExit(ctx, message.Err)
	a.changed(ctx, "runtime lost unexpectedly")
	if errors.Is(message.Err, application.ErrHostedRuntimeUnexpectedExit) && !a.binding.OwnershipIndeterminate {
		a.scheduleRecovery(ctx)
	}
}

func (a *HostedPiRuntimeActor) stop(ctx *actor.ReceiveContext, message *application.StopHostedPiRuntime) {
	a.recoveryToken++
	a.log(ctx, "stop_requested", "none")
	if a.busy {
		a.pendingStop = true
		if a.startCancel != nil {
			a.startCancel()
		}
		a.binding.State = application.HostedPiRuntimeStopping
		a.changed(ctx, "")
		respondOperation(ctx, message.Accepted, &application.OperationResult{Completed: true})
		return
	}
	if a.process == nil {
		if a.binding.State != application.HostedPiRuntimeDegraded || !a.binding.OwnershipIndeterminate {
			a.binding.State = application.HostedPiRuntimeStopped
			a.binding.BridgeReady = false
			a.changed(ctx, "")
			respondOperation(ctx, message.Accepted, &application.OperationResult{Completed: true})
		} else {
			respondOperation(ctx, message.Accepted, &application.OperationResult{Reason: a.lastFailure})
		}
		return
	}
	a.busy = true
	a.binding.State = application.HostedPiRuntimeStopping
	a.changed(ctx, "")
	respondOperation(ctx, message.Accepted, &application.OperationResult{Completed: true})
	system, self, process := ctx.ActorSystem(), ctx.Self(), a.process
	timeout := message.Timeout
	if timeout <= 0 || timeout > 10*time.Second {
		timeout = 5 * time.Second
	}
	go func() {
		stopCtx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()
		err := process.Stop(stopCtx)
		_ = system.NoSender().Tell(context.Background(), self, &application.HostedPiRuntimeStoppedResult{Err: err})
	}()
}

func (a *HostedPiRuntimeActor) stopped(ctx *actor.ReceiveContext, message *application.HostedPiRuntimeStoppedResult) {
	a.busy = false
	if message.Err != nil {
		a.lastFailure = boundedRuntimeFailure(message.Err)
		a.cleanupFailed = true
		a.binding.State = application.HostedPiRuntimeDegraded
		a.changed(ctx, "runtime cleanup failed")
		return
	}
	a.stopSucceeded = true
	a.lastFailure = ""
	if a.exitObserved {
		a.binding.State = application.HostedPiRuntimeStopped
		a.binding.BridgeReady = false
		a.changed(ctx, "")
	}
}

func (a *HostedPiRuntimeActor) scheduleRecovery(ctx *actor.ReceiveContext) {
	if a.recoveryAttempts >= maxHostedRuntimeRecoveryAttempts {
		a.log(ctx, "recovery_exhausted", "retry_budget_exhausted")
		a.changed(ctx, "runtime recovery exhausted")
		return
	}
	a.recoveryToken++
	token := a.recoveryToken
	delay := hostedRuntimeRecoveryDelays[a.recoveryAttempts]
	a.log(ctx, "recovery_scheduled", "unexpected_exit")
	_ = ctx.ActorSystem().ScheduleOnce(context.WithoutCancel(ctx.Context()), &application.RetryHostedPiRuntime{Token: token}, ctx.Self(), delay)
}

func (a *HostedPiRuntimeActor) retry(ctx *actor.ReceiveContext, message *application.RetryHostedPiRuntime) {
	if message.Token != a.recoveryToken || a.binding.State != application.HostedPiRuntimeDegraded || a.process != nil || a.busy || a.binding.OwnershipIndeterminate || a.recoveryAttempts >= maxHostedRuntimeRecoveryAttempts {
		return
	}
	a.recoveryAttempts++
	a.spec.Incarnation++
	previous := a.binding
	a.binding = application.InactiveHostedPiRuntimeBinding()
	a.binding.State = application.HostedPiRuntimeStarting
	a.binding.RuntimeID = a.spec.RuntimeID
	a.binding.Incarnation = a.spec.Incarnation
	a.binding.AggregateID = previous.AggregateID
	a.binding.DisplayName = previous.DisplayName
	a.binding.Role = previous.Role
	a.cleanupFailed = false
	a.exitObserved = false
	a.stopSucceeded = false
	a.pendingStop = false
	a.lastFailure = ""
	a.log(ctx, "recovery_started", "unexpected_exit")
	a.start(ctx, &application.StartHostedPiRuntime{Timeout: 10 * time.Second})
}

func (a *HostedPiRuntimeActor) log(ctx *actor.ReceiveContext, event, failureClass string) {
	ctx.ActorSystem().Logger().Infof("component=hosted_runtime event=%s agent_id=%s runtime_id=%s incarnation=%d recovery_attempt=%d failure_class=%s", event, a.spec.AgentID, a.spec.RuntimeID, a.spec.Incarnation, a.recoveryAttempts, failureClass)
}

func (a *HostedPiRuntimeActor) logExit(ctx *actor.ReceiveContext, err error) {
	status, signal := "unknown", "none"
	var reported interface {
		ExitStatus() string
		ExitSignal() string
	}
	if errors.As(err, &reported) {
		if reported.ExitStatus() != "" {
			status = boundedLogToken(reported.ExitStatus())
		}
		if reported.ExitSignal() != "" {
			signal = boundedLogToken(reported.ExitSignal())
		}
	}
	ctx.ActorSystem().Logger().Infof("component=hosted_runtime event=unexpected_exit agent_id=%s runtime_id=%s incarnation=%d recovery_attempt=%d failure_class=%s exit_status=%s exit_signal=%s", a.spec.AgentID, a.spec.RuntimeID, a.spec.Incarnation, a.recoveryAttempts, runtimeFailureClass(err), status, signal)
}

func boundedLogToken(value string) string {
	value = strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, value)
	if value == "" {
		return "unknown"
	}
	if len(value) > 3 {
		return value[:3]
	}
	return value
}

func runtimeFailureClass(err error) string {
	switch {
	case err == nil:
		return "process_exit"
	case errors.Is(err, application.ErrHostedOwnershipIndeterminate):
		return "ownership_indeterminate"
	case errors.Is(err, application.ErrHostedRuntimeUnexpectedExit):
		return "unexpected_exit"
	case errors.Is(err, context.DeadlineExceeded):
		return "deadline_exceeded"
	case errors.Is(err, context.Canceled):
		return "canceled"
	default:
		return "operation_failed"
	}
}

func boundedRuntimeFailure(err error) string {
	if err == nil {
		return "runtime process exited without an error"
	}
	value := err.Error()
	if len(value) > 240 {
		value = value[:240]
	}
	return value
}

func (a *HostedPiRuntimeActor) changed(ctx *actor.ReceiveContext, reason string) {
	if a.owner != nil {
		copy := a.binding
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), a.owner, &application.HostedPiRuntimeStateChanged{AgentID: a.spec.AgentID, Binding: copy, Reason: reason})
	}
}
