package actors

import (
	"testing"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

func TestRuntimeProjectionAdvanceRejectsSameIncarnationRegression(t *testing.T) {
	binding := func(state application.HostedPiRuntimeState, incarnation uint64) application.HostedPiRuntimeBinding {
		return application.HostedPiRuntimeBinding{RuntimeID: "runtime", State: state, Incarnation: incarnation}
	}
	for _, test := range []struct {
		name          string
		current, next application.HostedPiRuntimeBinding
		accepted      bool
	}{
		{name: "starting to ready", current: binding(application.HostedPiRuntimeStarting, 1), next: binding(application.HostedPiRuntimeReady, 1), accepted: true},
		{name: "ready remains ready", current: binding(application.HostedPiRuntimeReady, 1), next: binding(application.HostedPiRuntimeReady, 1), accepted: true},
		{name: "ready cannot regress to starting", current: binding(application.HostedPiRuntimeReady, 1), next: binding(application.HostedPiRuntimeStarting, 1)},
		{name: "degraded cannot revive same incarnation", current: binding(application.HostedPiRuntimeDegraded, 1), next: binding(application.HostedPiRuntimeReady, 1)},
		{name: "degraded recovers through next incarnation", current: binding(application.HostedPiRuntimeDegraded, 1), next: binding(application.HostedPiRuntimeStarting, 2), accepted: true},
		{name: "ready cannot skip to next incarnation", current: binding(application.HostedPiRuntimeReady, 1), next: binding(application.HostedPiRuntimeStarting, 2)},
		{name: "stopped is terminal", current: binding(application.HostedPiRuntimeStopped, 1), next: binding(application.HostedPiRuntimeReady, 1)},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := validRuntimeProjectionAdvance(test.current, test.next); got != test.accepted {
				t.Fatalf("advance=%v want %v", got, test.accepted)
			}
		})
	}
}
