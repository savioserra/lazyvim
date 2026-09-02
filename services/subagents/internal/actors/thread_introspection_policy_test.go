package actors

import "testing"

func TestWorkerResultCompletionPolicyRejectsAcknowledgementsAndPointers(t *testing.T) {
	for _, result := range []string{"", "ok", "done", "reconnaissance sent to client", "The report was sent elsewhere.", "See the other message"} {
		if workerResultContainsDeliverable([]byte(result)) {
			t.Fatalf("non-deliverable result was accepted: %q", result)
		}
	}
	for _, result := range []string{"The answer is 42.", "Implemented the scheduler and verified all race tests.", "Report:\n- finding one\n- finding two"} {
		if !workerResultContainsDeliverable([]byte(result)) {
			t.Fatalf("bounded deliverable was rejected: %q", result)
		}
	}
}
