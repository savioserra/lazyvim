package actors

import (
	"context"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

func TestWorkflowRegistryProgressesIndependentOfUIAndCleansByID(t *testing.T) {
	ctx := context.Background()
	system, err := actor.NewActorSystem("workflow-registry")
	if err != nil {
		t.Fatal(err)
	}
	if err := system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = system.Stop(ctx) })
	registry, err := system.Spawn(ctx, "registry", &WorkflowRegistryActor{})
	if err != nil {
		t.Fatal(err)
	}
	result := make(chan application.OperationResult, 1)
	if err := system.NoSender().Tell(ctx, registry, &application.StartWorkflow{WorkflowID: "wf", Task: "task", Result: result}); err != nil {
		t.Fatal(err)
	}
	select {
	case accepted := <-result:
		if !accepted.Completed {
			t.Fatalf("workflow not accepted: %#v", accepted)
		}
	case <-time.After(time.Second):
		t.Fatal("start timed out")
	}
	for _, stage := range []application.WorkflowStage{application.WorkflowStageWorker, application.WorkflowStageReviewer, application.WorkflowStageQA} {
		if err := system.NoSender().Tell(ctx, registry, &application.WorkflowStageResult{WorkflowID: "wf", Stage: stage, Evidence: "evidence", Accepted: true}); err != nil {
			t.Fatal(err)
		}
	}
	value, err := system.NoSender().Ask(ctx, registry, &application.WorkflowStatus{WorkflowID: "wf"}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	state := value.(*application.WorkflowState)
	if !state.Terminal || state.Stage != application.WorkflowStageCompleted || len(state.Evidence) != 3 {
		t.Fatalf("unexpected workflow state: %#v", state)
	}
	child, err := system.ActorOf(ctx, "workflow-wf")
	if err != nil {
		t.Fatal(err)
	}
	_ = child.Shutdown(ctx)
	time.Sleep(20 * time.Millisecond)
	result = make(chan application.OperationResult, 1)
	if err := system.NoSender().Tell(ctx, registry, &application.StartWorkflow{WorkflowID: "wf", Task: "again", Result: result}); err != nil {
		t.Fatal(err)
	}
	select {
	case accepted := <-result:
		if !accepted.Completed {
			t.Fatalf("workflow did not restart after death-watch cleanup: %#v", accepted)
		}
	case <-time.After(time.Second):
		t.Fatal("restart timed out")
	}
}

func TestTaskCoordinatorStallQuarantinesTerminal(t *testing.T) {
	ctx := context.Background()
	system, err := actor.NewActorSystem("task-coordinator")
	if err != nil {
		t.Fatal(err)
	}
	if err := system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = system.Stop(ctx) })
	pid, err := system.Spawn(ctx, "coordinator", &TaskCoordinatorActor{})
	if err != nil {
		t.Fatal(err)
	}
	if err := system.NoSender().Tell(ctx, pid, &application.RetryCoordination{SessionID: "task"}); err != nil {
		t.Fatal(err)
	}
	value, err := system.NoSender().Ask(ctx, pid, &application.WorkflowStatus{WorkflowID: "task"}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	state := value.(application.WorkflowState)
	if !state.Terminal || state.Stage != application.WorkflowStageFailed || state.Reason == "" {
		t.Fatalf("stall was not quarantined: %#v", state)
	}
}
