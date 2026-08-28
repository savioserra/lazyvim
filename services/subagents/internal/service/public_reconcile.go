package service

import (
	"context"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

func (s *Service) reconcilePublicHostedPeers(ctx context.Context) {
	if s.actorPlane == nil || s.publicDirectory == nil {
		return
	}
	for _, node := range publicNodeMap(s.actorPlane) {
		if node.Identity == s.actorPlane.NodeIdentity || node.Stale || node.Host == "" || node.Port <= 0 {
			continue
		}
		_ = s.reconcilePublicHostedPeer(ctx, node)
	}
}

func (s *Service) reconcilePublicHostedPeer(ctx context.Context, node application.PublicNode) error {
	pid, err := s.system.NoSender().RemoteLookup(ctx, node.Host, node.Port, placementAuthorityName(node.Identity))
	if err != nil || pid == nil {
		return err
	}
	value, err := s.system.NoSender().Ask(ctx, pid, &application.ListPublicHostedAgents{Limit: 256}, requestTimeout)
	if err != nil {
		return err
	}
	result, ok := value.(*application.ListPublicHostedAgentsResult)
	if !ok || result.Reason != "" {
		return nil
	}
	for _, item := range result.Agents {
		_, _ = s.system.NoSender().Ask(ctx, s.publicDirectory, &application.CreatePublicAgent{Internal: true, AgentID: item.AgentID, ActorName: placementAuthorityName(node.Identity), Reference: item.Reference, Placement: application.PublicAgentPlacement{NodeIdentity: node.Identity}}, min(requestTimeout, boundedRemaining(ctx, time.Second)))
	}
	return nil
}
