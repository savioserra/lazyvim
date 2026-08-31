package service_test

import (
	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
)

// identityBridgeAck mirrors the internal service helper: it stamps a bridge
// delivery acknowledgement with the identity the target actor enforces.
func identityBridgeAck(agentID, runtimeID, piSessionID string, incarnation uint64, delivery *subagentsv1.BridgeDelivery, delivered bool, result []byte) *subagentsv1.BridgeDeliveryAckRequest {
	kind := ""
	switch delivery.Kind {
	case subagentsv1.BridgeDelivery_KIND_NOTIFICATION:
		kind = "notification"
	case subagentsv1.BridgeDelivery_KIND_ABORT:
		kind = "abort"
	case subagentsv1.BridgeDelivery_KIND_SHUTDOWN:
		kind = "shutdown"
	case subagentsv1.BridgeDelivery_KIND_PROMPT:
		kind = "prompt"
	}
	return &subagentsv1.BridgeDeliveryAckRequest{AgentId: agentID, Sequence: delivery.Sequence, DedupeId: delivery.DedupeId, Delivered: delivered, BoundedResult: result, RuntimeId: runtimeID, Incarnation: incarnation, PiSessionId: piSessionID, Kind: kind, SourceScope: delivery.SourceScope, CompletionKey: delivery.CompletionKey}
}
