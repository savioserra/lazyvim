package service

import (
	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"testing"
)

func TestGeneratedUnknownHostedLifecycleEnumsAreRejected(t *testing.T) {
	for _, event := range []subagentsv1.BridgeLifecycleRequest_Event{0, 6, 99, -1} {
		if _, ok := bridgeLifecycleEvent(event); ok {
			t.Fatalf("generated unknown lifecycle enum %d was accepted", event)
		}
	}
	for _, event := range []subagentsv1.BridgeLifecycleRequest_Event{subagentsv1.BridgeLifecycleRequest_EVENT_SESSION_START, subagentsv1.BridgeLifecycleRequest_EVENT_READY, subagentsv1.BridgeLifecycleRequest_EVENT_SESSION_SHUTDOWN, subagentsv1.BridgeLifecycleRequest_EVENT_AGENT_START, subagentsv1.BridgeLifecycleRequest_EVENT_AGENT_SETTLED} {
		if _, ok := bridgeLifecycleEvent(event); !ok {
			t.Fatalf("known lifecycle enum %d was rejected", event)
		}
	}
}
