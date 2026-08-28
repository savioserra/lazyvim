package service

import (
	"context"
	"errors"
	"fmt"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

func (s *Service) remoteHostedAdminResponse(ctx context.Context, request *subagentsv1.Envelope, command *subagentsv1.HostedAdminRequest) *subagentsv1.Envelope {
	response := responseEnvelope(request)
	if command.Operation != subagentsv1.HostedAdminRequest_OPERATION_START {
		response.Payload = protocolError(subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "remote hosted placement supports start only")
		return response
	}
	if s.publicDirectory == nil || s.actorPlane == nil {
		response.Payload = protocolError(subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "remote hosted placement is not configured")
		return response
	}
	node, ok := publicNodeMap(s.actorPlane)[command.TargetNode]
	if !ok || node.Stale || node.Host == "" || node.Port <= 0 {
		response.Payload = protocolError(subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "remote hosted placement node unavailable")
		return response
	}
	pid, err := s.system.NoSender().RemoteLookup(ctx, node.Host, node.Port, hostedPlacementAuthorityName)
	if err != nil || pid == nil {
		response.Payload = protocolError(subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "remote hosted placement authority unavailable")
		return response
	}
	placement, err := s.signRemotePlacement(ctx, node, request.RequestId, request.DeadlineUnixMillis, command.AgentId, command.ProjectDirectory, command.DisplayName, command.Role, command.TrustProject)
	if err != nil {
		response.Payload = protocolError(subagentsv1.ProtocolError_CODE_INTERNAL, "remote hosted placement signing failed")
		return response
	}
	value, err := s.system.NoSender().Ask(ctx, pid, placement, requestTimeout)
	if err != nil {
		response.Payload = protocolError(subagentsv1.ProtocolError_CODE_INTERNAL, fmt.Sprintf("remote hosted placement failed: %v", err))
		return response
	}
	placed, ok := value.(*application.RemoteHostedPlacementResult)
	if !ok || !placed.Accepted || placed.ActorName == "" {
		reason := "remote hosted placement rejected"
		if ok && placed.Reason != "" {
			reason = placed.Reason
		}
		response.Payload = &subagentsv1.Envelope_HostedAdminResponse{HostedAdminResponse: &subagentsv1.HostedAdminResponse{AgentId: command.AgentId, Reason: reason}}
		return response
	}
	if err := s.recordRemotePublicAgent(ctx, request, command, node, placed); err != nil {
		response.Payload = protocolError(subagentsv1.ProtocolError_CODE_INTERNAL, err.Error())
		return response
	}
	response.Payload = &subagentsv1.Envelope_HostedAdminResponse{HostedAdminResponse: &subagentsv1.HostedAdminResponse{Accepted: true, AgentId: command.AgentId, Runtime: protoAgentReference(placed.Reference).HostedPiRuntime}}
	return response
}

func (s *Service) recordRemotePublicAgent(ctx context.Context, request *subagentsv1.Envelope, command *subagentsv1.HostedAdminRequest, node application.PublicNode, placed *application.RemoteHostedPlacementResult) error {
	if s.publicDirectory == nil {
		return errors.New("public directory unavailable")
	}
	value, err := s.system.NoSender().Ask(ctx, s.publicDirectory, &application.CreatePublicAgent{SessionID: request.SessionId, GenerationID: request.GenerationId, Caller: request.CallerIdentity, Credential: request.SessionCredential, AgentID: command.AgentId, Role: command.Role, DisplayName: command.DisplayName, ActorName: placed.ActorName, Reference: placed.Reference, Placement: application.PublicAgentPlacement{NodeIdentity: node.Identity}, Internal: true}, requestTimeout)
	if err != nil {
		return err
	}
	result, ok := value.(*application.PublicAgentCreateResult)
	if !ok || !result.Created {
		if ok && result.Reason != "" {
			return errors.New(result.Reason)
		}
		return errors.New("public directory rejected remote hosted agent")
	}
	return nil
}
