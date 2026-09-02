package application

import (
	"context"
	"time"
)

const (
	MaxThreadIntrospectionJSONBytes = 16 * 1024
	MaxThreadCheckpointBytes        = 4 * 1024
	MaxThreadWaitConditionBytes     = 1024
	MaxThreadCompletionSummaryBytes = 2 * 1024
)

type ThreadIntrospectionState string

type ThreadIntrospectionConfidence string

type ThreadIntrospectionReasonClass string

const (
	ThreadIntrospectionCompleted ThreadIntrospectionState = "completed"
	ThreadIntrospectionContinue  ThreadIntrospectionState = "continue"
	ThreadIntrospectionWaiting   ThreadIntrospectionState = "waiting"
	ThreadIntrospectionBlocked   ThreadIntrospectionState = "blocked"

	ThreadIntrospectionConfidenceLow    ThreadIntrospectionConfidence = "low"
	ThreadIntrospectionConfidenceMedium ThreadIntrospectionConfidence = "medium"
	ThreadIntrospectionConfidenceHigh   ThreadIntrospectionConfidence = "high"

	ThreadIntrospectionDone              ThreadIntrospectionReasonClass = "done"
	ThreadIntrospectionNeedsMoreWork     ThreadIntrospectionReasonClass = "needs_more_work"
	ThreadIntrospectionWaitingOnUser     ThreadIntrospectionReasonClass = "waiting_on_user"
	ThreadIntrospectionWaitingOnExternal ThreadIntrospectionReasonClass = "waiting_on_external"
	ThreadIntrospectionBlockedByError    ThreadIntrospectionReasonClass = "blocked_by_error"
)

// ThreadIntrospectionInput is owner-private model input. The daemon binds it to
// the active thread/turn/lease outside the model prompt; actor and runtime
// identity must never be exposed to the classifier.
type ThreadIntrospectionInput struct {
	TaskPrompt   string `json:"task_prompt"`
	WorkerResult string `json:"worker_result"`
	Checkpoint   string `json:"checkpoint"`
}

type ThreadIntrospectionResult struct {
	State             ThreadIntrospectionState       `json:"state"`
	Confidence        ThreadIntrospectionConfidence  `json:"confidence"`
	ReasonClass       ThreadIntrospectionReasonClass `json:"reason_class"`
	Checkpoint        string                         `json:"checkpoint"`
	NextPrompt        string                         `json:"next_prompt"`
	WaitCondition     string                         `json:"wait_condition"`
	CompletionSummary string                         `json:"completion_summary"`
}

type ThreadIntrospectionAttempt struct {
	AgentID          string
	RuntimeID        string
	Incarnation      uint64
	ThreadID         string
	SchedulerEpoch   uint64
	ActiveLease      uint64
	ThreadTurn       uint64
	DeliverySequence uint64
	BridgeRunCounter uint64
	AttemptID        string
	Input            ThreadIntrospectionInput
	Timeout          time.Duration
}

type ThreadIntrospectionOutcome struct {
	Attempt      ThreadIntrospectionAttempt
	Result       ThreadIntrospectionResult
	FailureClass string
}

type ThreadIntrospectionRunner interface {
	Run(context.Context, ThreadIntrospectionInput) (ThreadIntrospectionResult, error)
}
