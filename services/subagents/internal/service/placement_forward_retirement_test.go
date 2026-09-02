package service

import (
	"context"
	"testing"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

func TestPlacementAuthorityRejectsDirectModelIntentBeforeResolution(t *testing.T) {
	authority := &hostedPlacementAuthority{}
	for _, mode := range []application.BridgeMessageMode{application.BridgeMessageAsk, application.BridgeMessagePrompt} {
		result := authority.remoteBridgeIntent(context.Background(), &application.RemoteBridgeIntent{Mode: mode, TargetAgentID: "unresolved"})
		if result.Accepted || result.Reason != "model-bearing bridge intent retired; use actor task" {
			t.Fatalf("mode %d was not rejected before placement resolution: %#v", mode, result)
		}
	}
}
