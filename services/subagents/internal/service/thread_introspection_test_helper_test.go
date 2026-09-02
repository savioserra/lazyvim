package service

import (
	"context"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

type testCompletedIntrospectionRunner struct{}

func (testCompletedIntrospectionRunner) Run(context.Context, application.ThreadIntrospectionInput) (application.ThreadIntrospectionResult, error) {
	return application.ThreadIntrospectionResult{State: application.ThreadIntrospectionCompleted, Confidence: application.ThreadIntrospectionConfidenceHigh, ReasonClass: application.ThreadIntrospectionDone, Checkpoint: "done", CompletionSummary: "completed"}, nil
}
