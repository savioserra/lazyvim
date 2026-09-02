package service

import (
	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
)

// identityBridgeAck stamps a bridge delivery acknowledgement with the runtime,
// incarnation, Pi session, delivery kind, source scope, and completion key the
// target actor enforces fail-closed before any acknowledgement effects.
func identityBridgeAck(agentID, runtimeID, piSessionID string, incarnation uint64, delivery *subagentsv1.BridgeDelivery, delivered bool, result []byte) *subagentsv1.BridgeDeliveryAckRequest {
	request := &subagentsv1.BridgeDeliveryAckRequest{AgentId: agentID, Sequence: delivery.Sequence, DedupeId: delivery.DedupeId, Delivered: delivered, BoundedResult: result, RuntimeId: runtimeID, Incarnation: incarnation, PiSessionId: piSessionID, Kind: deliveryKindLabel(delivery.Kind), SourceScope: delivery.SourceScope, CompletionKey: delivery.CompletionKey, ThreadId: delivery.ThreadId, SchedulerEpoch: delivery.SchedulerEpoch, ActiveLease: delivery.ActiveLease, ThreadTurn: delivery.ThreadTurn}
	if delivery.ThreadId != "" {
		request.BridgeRunCounter = delivery.Sequence
		request.AgentEndObserved = delivered
		request.AgentSettledObserved = delivered
	}
	return request
}
