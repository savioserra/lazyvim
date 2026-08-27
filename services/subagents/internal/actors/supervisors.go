package actors

import (
	"context"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

// HostedRuntimeSupervisor is the bounded GoAkt lifecycle boundary for hosted
// runtimes. It does not perform effects in Receive; child runtime actors own
// process effects and report typed state changes.
type HostedRuntimeSupervisor struct{ children map[string]*actor.PID }

func (s *HostedRuntimeSupervisor) PreStart(*actor.Context) error {
	s.children = make(map[string]*actor.PID)
	return nil
}
func (*HostedRuntimeSupervisor) PostStop(*actor.Context) error { return nil }
func (s *HostedRuntimeSupervisor) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *application.BindHostedPiRuntimeActor:
		if message.PID != nil {
			s.children[message.PID.Name()] = message.PID
			ctx.Watch(message.PID)
		}
	case *actor.Terminated:
		delete(s.children, message.ActorPath().Name())
	default:
		ctx.Unhandled()
	}
}

// PersistenceSupervisor tracks fail-closed durable quarantine. Writers report
// indeterminate durable effects here; health checks or operators can inspect the
// quarantine rather than continuing as if persistence were reliable.
type PersistenceSupervisor struct{ quarantine map[string]string }

func (s *PersistenceSupervisor) PreStart(*actor.Context) error {
	s.quarantine = make(map[string]string)
	return nil
}
func (*PersistenceSupervisor) PostStop(*actor.Context) error { return nil }
func (s *PersistenceSupervisor) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *application.QuarantineDurableHostedState:
		reason := message.Reason
		if reason == "" && message.Err != nil {
			reason = message.Err.Error()
		}
		if reason == "" {
			reason = "durable state quarantined"
		}
		s.quarantine[message.AgentID] = reason
	case *application.DurableQuarantineStatus:
		items := make(map[string]string, len(s.quarantine))
		for key, value := range s.quarantine {
			items[key] = value
		}
		ctx.Response(&application.DurableQuarantineState{FailClosed: len(items) != 0, Items: items})
	default:
		ctx.Unhandled()
	}
}

// ClientSessionActor is the per-client authority lifetime boundary. It exists
// so disconnect cleanup removes credentials/views without affecting global
// AgentActors.
type ClientSessionActor struct{ sessionID, generationID, principal string }

func NewClientSessionActor(sessionID, generationID, principal string) *ClientSessionActor {
	return &ClientSessionActor{sessionID: sessionID, generationID: generationID, principal: principal}
}
func (*ClientSessionActor) PreStart(*actor.Context) error { return nil }
func (*ClientSessionActor) PostStop(*actor.Context) error { return nil }
func (a *ClientSessionActor) Receive(ctx *actor.ReceiveContext) {
	switch ctx.Message().(type) {
	case *application.Health:
		ctx.Response(&application.HealthState{Live: true, Ready: true, Status: a.sessionID})
	default:
		ctx.Unhandled()
	}
}

// WorkflowRegistryActor owns workflow actors independently from any PM UI.
type WorkflowRegistryActor struct {
	workflows map[string]*actor.PID
	states    map[string]application.WorkflowState
}

func (*WorkflowRegistryActor) PostStop(*actor.Context) error { return nil }
func (r *WorkflowRegistryActor) PreStart(*actor.Context) error {
	r.workflows = make(map[string]*actor.PID)
	r.states = make(map[string]application.WorkflowState)
	return nil
}
func (r *WorkflowRegistryActor) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *application.StartWorkflow:
		if message.WorkflowID == "" {
			deliverOperationResult(message.Result, application.OperationResult{Reason: "workflow id is required"})
			return
		}
		if pid := r.workflows[message.WorkflowID]; pid != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), pid, message)
			return
		}
		pid := ctx.Spawn("workflow-"+message.WorkflowID, NewWorkflowActor(message.WorkflowID), actor.WithMailbox(actor.NewNonBlockingBoundedMailbox(128)))
		if pid == nil {
			deliverOperationResult(message.Result, application.OperationResult{Reason: "workflow spawn failed"})
			return
		}
		r.workflows[message.WorkflowID] = pid
		r.states[message.WorkflowID] = application.WorkflowState{WorkflowID: message.WorkflowID, Stage: application.WorkflowStageWorker}
		ctx.Watch(pid)
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), pid, message)
	case *application.WorkflowStageResult:
		state := r.states[message.WorkflowID]
		state.WorkflowID = message.WorkflowID
		if message.Evidence != "" {
			state.Evidence = append(state.Evidence, message.Evidence)
		}
		if !message.Accepted {
			state.Stage = application.WorkflowStageCorrection
			state.Reason = message.Reason
		} else {
			switch message.Stage {
			case application.WorkflowStageWorker:
				state.Stage = application.WorkflowStageReviewer
			case application.WorkflowStageReviewer:
				state.Stage = application.WorkflowStageQA
			case application.WorkflowStageQA, application.WorkflowStageCorrection:
				state.Stage, state.Terminal = application.WorkflowStageCompleted, true
			}
		}
		r.states[message.WorkflowID] = state
		if pid := r.workflows[message.WorkflowID]; pid != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), pid, message)
		}
	case *application.WorkflowStatus:
		if state, ok := r.states[message.WorkflowID]; ok {
			copyEvidence := append([]string(nil), state.Evidence...)
			state.Evidence = copyEvidence
			ctx.Response(&state)
			return
		}
		ctx.Response(&application.WorkflowState{WorkflowID: message.WorkflowID, Terminal: true, Reason: "workflow not found"})
	case *actor.Terminated:
		name := message.ActorPath().Name()
		for id, pid := range r.workflows {
			if pid != nil && pid.Name() == name {
				delete(r.workflows, id)
			}
		}
	default:
		ctx.Unhandled()
	}
}

// WorkflowActor implements a bounded worker -> reviewer -> QA -> correction
// progression. UI actors may observe it but are not required for progress.
type WorkflowActor struct {
	id       string
	stage    application.WorkflowStage
	evidence []string
	terminal bool
	reason   string
}

func NewWorkflowActor(id string) *WorkflowActor {
	return &WorkflowActor{id: id, stage: application.WorkflowStageWorker}
}
func (*WorkflowActor) PreStart(*actor.Context) error { return nil }
func (*WorkflowActor) PostStop(*actor.Context) error { return nil }
func (w *WorkflowActor) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *application.StartWorkflow:
		if w.terminal {
			deliverOperationResult(message.Result, application.OperationResult{Completed: w.stage == application.WorkflowStageCompleted, Reason: w.reason})
			return
		}
		if message.Result != nil {
			deliverOperationResult(message.Result, application.OperationResult{Completed: true, Reason: "workflow accepted"})
		}
	case *application.WorkflowStageResult:
		if message.WorkflowID != w.id || w.terminal {
			return
		}
		if message.Evidence != "" {
			w.evidence = append(w.evidence, message.Evidence)
		}
		if !message.Accepted {
			w.stage = application.WorkflowStageCorrection
			w.reason = message.Reason
			return
		}
		switch message.Stage {
		case application.WorkflowStageWorker:
			w.stage = application.WorkflowStageReviewer
		case application.WorkflowStageReviewer:
			w.stage = application.WorkflowStageQA
		case application.WorkflowStageQA, application.WorkflowStageCorrection:
			w.stage, w.terminal = application.WorkflowStageCompleted, true
		}
	case *application.WorkflowStatus:
		copyEvidence := append([]string(nil), w.evidence...)
		ctx.Response(&application.WorkflowState{WorkflowID: w.id, Stage: w.stage, Evidence: copyEvidence, Terminal: w.terminal, Reason: w.reason})
	default:
		ctx.Unhandled()
	}
}

// TaskCoordinatorActor is an actor-owned task progress ledger. Model effects
// still run outside Receive and report typed outcomes, giving progress evidence
// and stall recovery without polling.
type TaskCoordinatorActor struct {
	tasks map[string]application.WorkflowState
}

func (t *TaskCoordinatorActor) PreStart(*actor.Context) error {
	t.tasks = make(map[string]application.WorkflowState)
	return nil
}
func (*TaskCoordinatorActor) PostStop(*actor.Context) error { return nil }
func (t *TaskCoordinatorActor) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *application.WorkflowStageResult:
		state := t.tasks[message.WorkflowID]
		state.WorkflowID = message.WorkflowID
		state.Stage = message.Stage
		if message.Evidence != "" {
			state.Evidence = append(state.Evidence, message.Evidence)
		}
		state.Terminal = message.Accepted && message.Stage == application.WorkflowStageCompleted
		state.Reason = message.Reason
		t.tasks[message.WorkflowID] = state
	case *application.WorkflowStatus:
		ctx.Response(t.tasks[message.WorkflowID])
	case *application.RetryCoordination:
		state := t.tasks[message.SessionID]
		state.WorkflowID = message.SessionID
		state.Stage = application.WorkflowStageFailed
		state.Terminal = true
		state.Reason = "task stalled and was quarantined"
		t.tasks[message.SessionID] = state
	default:
		ctx.Unhandled()
	}
}
