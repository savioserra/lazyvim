package service

import (
	"testing"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

func TestTaskLifecycleFailureStateClassification(t *testing.T) {
	cases := map[string]subagentsv1.TaskLifecycleResponse_State{
		"task prompt completion deadline expired": subagentsv1.TaskLifecycleResponse_STATE_TIMEOUT,
		"target actor not alive":                  subagentsv1.TaskLifecycleResponse_STATE_ACTOR_LOST,
		"model rejected the prompt":               subagentsv1.TaskLifecycleResponse_STATE_FAILED,
	}
	for reason, expected := range cases {
		if actual := taskLifecycleFailureState(reason); actual != expected {
			t.Fatalf("%q classified as %v, want %v", reason, actual, expected)
		}
	}
}

func TestTaskLifecycleRunnerReportsTimeoutAndFailure(t *testing.T) {
	service := &Service{}
	timed := &taskLifecycle{id: "timed", state: subagentsv1.TaskLifecycleResponse_STATE_ACCEPTED, done: make(chan struct{})}
	service.runTaskLifecycle(timed, make(chan application.BridgeIntentResult), make(chan application.BridgeIntentResult), time.Now().Add(5*time.Millisecond))
	if timed.state != subagentsv1.TaskLifecycleResponse_STATE_TIMEOUT || !taskLifecycleTerminal(timed.state) {
		t.Fatalf("timeout state not reported: %#v", timed)
	}

	failed := &taskLifecycle{id: "failed", state: subagentsv1.TaskLifecycleResponse_STATE_ACCEPTED, done: make(chan struct{})}
	receipt := make(chan application.BridgeIntentResult, 1)
	receipt <- application.BridgeIntentResult{Reason: "model rejected the prompt"}
	service.runTaskLifecycle(failed, receipt, make(chan application.BridgeIntentResult), time.Now().Add(time.Second))
	if failed.state != subagentsv1.TaskLifecycleResponse_STATE_FAILED || !taskLifecycleTerminal(failed.state) {
		t.Fatalf("failure state not reported: %#v", failed)
	}
}
