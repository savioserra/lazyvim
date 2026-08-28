package service

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

const hostedPlacementAuthorityNamePrefix = "hosted-placement-authority-v2-"

func placementAuthorityName(nodeIdentity string) string {
	digest := sha256.Sum256([]byte(nodeIdentity))
	return hostedPlacementAuthorityNamePrefix + fmt.Sprintf("%x", digest[:8])
}

type placementReplay struct {
	digest [32]byte
	result application.RemoteHostedPlacementResult
}

type hostedPlacementAuthority struct {
	service *Service
	replays map[string]placementReplay
	order   []string
}

func (a *hostedPlacementAuthority) PreStart(*actor.Context) error {
	if a.replays == nil {
		a.replays = make(map[string]placementReplay)
	}
	return nil
}
func (*hostedPlacementAuthority) PostStop(*actor.Context) error { return nil }
func (a *hostedPlacementAuthority) Receive(ctx *actor.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *application.RemoteHostedPlacement:
		ctx.Response(a.place(ctx.Context(), message))
	case *application.ListPublicHostedAgents:
		ctx.Response(a.list(ctx.Context(), message))
	case *application.RemoteAttachAgent:
		ctx.Response(a.remoteAttach(ctx.Context(), message))
	case *application.RemoteBridgeIntent:
		ctx.Response(a.remoteBridgeIntent(ctx.Context(), message))
	default:
		ctx.Unhandled()
	}
}

func (a *hostedPlacementAuthority) place(ctx context.Context, message *application.RemoteHostedPlacement) *application.RemoteHostedPlacementResult {
	if err := a.verifyPlacement(message); err != nil {
		return &application.RemoteHostedPlacementResult{Reason: err.Error()}
	}
	digest := remotePlacementDigest(message)
	if replay, ok := a.replays[message.OperationID]; ok {
		if replay.digest != digest {
			return &application.RemoteHostedPlacementResult{Reason: "placement operation collision"}
		}
		result := replay.result
		return &result
	}
	result := a.placeOnce(ctx, message)
	a.replays[message.OperationID] = placementReplay{digest: digest, result: *result}
	a.order = append(a.order, message.OperationID)
	if len(a.order) > maxRequestResults {
		delete(a.replays, a.order[0])
		a.order = a.order[1:]
	}
	return result
}

func (a *hostedPlacementAuthority) placeOnce(ctx context.Context, message *application.RemoteHostedPlacement) *application.RemoteHostedPlacementResult {
	command := &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: message.AgentID, ProjectDirectory: message.ProjectDirectory, TrustProject: message.TrustProject, DisplayName: message.DisplayName, Role: message.Role}
	binding, err := a.service.startHostedAgent(ctx, command)
	if err != nil && !errors.Is(err, application.ErrHostedOwnershipIndeterminate) {
		if existing := a.resolveExisting(ctx, message.AgentID, binding); existing.Accepted {
			return existing
		}
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

func (a *hostedPlacementAuthority) list(ctx context.Context, message *application.ListPublicHostedAgents) *application.ListPublicHostedAgentsResult {
	if a.service == nil || a.service.agentRegistry == nil {
		return &application.ListPublicHostedAgentsResult{Reason: "placement authority unavailable"}
	}
	limit := message.Limit
	if limit == 0 || limit > 256 {
		limit = 256
	}
	value, err := a.service.system.NoSender().Ask(ctx, a.service.agentRegistry, &application.ListPublicHostedAgents{Limit: limit}, requestTimeout)
	if err != nil {
		return &application.ListPublicHostedAgentsResult{Reason: err.Error()}
	}
	result, ok := value.(*application.ListPublicHostedAgentsResult)
	if !ok {
		return &application.ListPublicHostedAgentsResult{Reason: "unexpected public hosted list response"}
	}
	return result
}

func remotePlacementDigest(message *application.RemoteHostedPlacement) [32]byte {
	return sha256.Sum256([]byte(message.DedupeID + "\x00" + message.AgentID + "\x00" + message.ProjectDirectory + "\x00" + message.DisplayName + "\x00" + message.Role))
}
