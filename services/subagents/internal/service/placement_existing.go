package service

import (
	"context"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

func (a *hostedPlacementAuthority) resolveExisting(ctx context.Context, agentID string, binding application.HostedPiRuntimeBinding) *application.RemoteHostedPlacementResult {
	value, err := a.service.system.NoSender().Ask(ctx, a.service.agentRegistry, &application.ResolveAgentControl{AgentID: agentID}, min(requestTimeout, boundedRemaining(ctx, time.Second)))
	if err != nil {
		return &application.RemoteHostedPlacementResult{}
	}
	control, ok := value.(*application.AgentControlPID)
	if !ok || !control.Found || control.PID == nil {
		return &application.RemoteHostedPlacementResult{}
	}
	if binding.RuntimeID == "" {
		binding = control.Reference.HostedPiRuntime
	}
	return &application.RemoteHostedPlacementResult{Accepted: true, AgentID: agentID, ActorName: control.PID.Name(), Reference: control.Reference, Runtime: binding}
}
