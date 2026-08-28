package service

import (
	"context"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

const hostedPlacementAuthorityName = "hosted-placement-authority"

type hostedPlacementAuthority struct{ service *Service }

func (*hostedPlacementAuthority) PreStart(*actor.Context) error { return nil }
func (*hostedPlacementAuthority) PostStop(*actor.Context) error { return nil }
func (a *hostedPlacementAuthority) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *application.RemoteHostedPlacement:
		ctx.Response(a.place(ctx.Context(), message))
	default:
		ctx.Unhandled()
	}
}

func (a *hostedPlacementAuthority) place(ctx context.Context, message *application.RemoteHostedPlacement) *application.RemoteHostedPlacementResult {
	if message == nil || !a.service.authorizedAdmin(message.AdminCredential) {
		return &application.RemoteHostedPlacementResult{Reason: "placement authorization denied"}
	}
	command := &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: message.AgentID, ProjectDirectory: message.ProjectDirectory, TrustProject: message.TrustProject, DisplayName: message.DisplayName, Role: message.Role}
	binding, err := a.service.startHostedAgent(ctx, command)
	if err != nil {
		return &application.RemoteHostedPlacementResult{AgentID: message.AgentID, Reason: err.Error()}
	}
	value, err := a.service.system.NoSender().Ask(ctx, a.service.agentRegistry, &application.ResolveAgentControl{AgentID: message.AgentID}, min(requestTimeout, boundedRemaining(ctx, time.Second)))
	if err != nil {
		return &application.RemoteHostedPlacementResult{AgentID: message.AgentID, Runtime: binding, Reason: "resolve created hosted agent"}
	}
	control, ok := value.(*application.AgentControlPID)
	if !ok || !control.Found || control.PID == nil {
		return &application.RemoteHostedPlacementResult{AgentID: message.AgentID, Runtime: binding, Reason: "created hosted agent unavailable"}
	}
	return &application.RemoteHostedPlacementResult{Accepted: true, AgentID: message.AgentID, ActorName: control.PID.Name(), Reference: control.Reference, Runtime: binding}
}
