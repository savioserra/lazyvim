package actors

import (
	"context"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

type restartIntrospectionRunner struct {
	calls chan application.ThreadIntrospectionInput
}

func (r restartIntrospectionRunner) Run(_ context.Context, input application.ThreadIntrospectionInput) (application.ThreadIntrospectionResult, error) {
	r.calls <- input
	return application.ThreadIntrospectionResult{State: application.ThreadIntrospectionWaiting, Confidence: application.ThreadIntrospectionConfidenceMedium, ReasonClass: application.ThreadIntrospectionWaitingOnExternal, Checkpoint: "checkpoint", WaitCondition: "external"}, nil
}

func TestRestoredSettledAndIntrospectingThreadsRedriveIntrospection(t *testing.T) {
	for _, state := range []application.AgentThreadState{application.AgentThreadSettled, application.AgentThreadIntrospecting} {
		t.Run(string(state), func(t *testing.T) {
			ctx := context.Background()
			system, err := actor.NewActorSystem("thread-introspection-restart-" + string(state))
			if err != nil {
				t.Fatal(err)
			}
			if err := system.Start(ctx); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				stop, cancel := context.WithTimeout(context.Background(), 3*time.Second)
				defer cancel()
				_ = system.Stop(stop)
			})
			calls := make(chan application.ThreadIntrospectionInput, 1)
			thread := schedulerThread("thread", state, 7, time.Time{})
			thread.TaskPrompt = []byte("task")
			thread.WorkerResult = []byte("worker result")
			thread.Checkpoint = "prior"
			thread.Turn = 1
			thread.IntrospectionAttempts = 1
			if state == application.AgentThreadIntrospecting {
				thread.IntrospectionAttemptID = "retained-attempt"
			} else {
				thread.IntrospectionAttempts = 0
			}
			record := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, AgentID: "target", Binding: application.InactiveHostedPiRuntimeBinding(), AgentState: application.DurableAgentState{Threads: []application.DurableAgentThread{thread}, ThreadScheduler: application.DurableThreadScheduler{SchemaVersion: application.DurableThreadSchedulerSchemaV1, AgentID: "target", ActiveThreadID: thread.ThreadID, Epoch: 3, ActiveLease: 4}}}
			agent := NewAgentActor(&application.RegisterAgent{AgentID: "target", HostedPiRuntime: record.Binding, DurableRecord: &record, IntrospectionRunner: restartIntrospectionRunner{calls: calls}})
			if _, err := system.Spawn(ctx, "thread-agent-"+string(state), agent); err != nil {
				t.Fatal(err)
			}
			select {
			case input := <-calls:
				if input.TaskPrompt != "task" || input.WorkerResult != "worker result" || input.Checkpoint != "prior" {
					t.Fatalf("restart changed isolated input: %#v", input)
				}
			case <-time.After(time.Second):
				t.Fatal("restored introspection was not redriven")
			}
		})
	}
}

func TestThreadAttemptIdentityAndBackoffAreDeterministic(t *testing.T) {
	thread := application.DurableAgentThread{ThreadID: "thread", Turn: 2}
	scheduler := application.DurableThreadScheduler{Epoch: 3, ActiveLease: 4}
	first := threadAttemptID(thread, scheduler, 1)
	if first == "" || first != threadAttemptID(thread, scheduler, 1) {
		t.Fatal("attempt identity is not deterministic")
	}
	scheduler.ActiveLease++
	if first == threadAttemptID(thread, scheduler, 1) {
		t.Fatal("active lease was omitted from attempt identity")
	}
	if threadIntrospectionBackoff(1) != time.Second || threadIntrospectionBackoff(32) != 5*time.Minute {
		t.Fatal("introspection backoff bounds changed")
	}
}
