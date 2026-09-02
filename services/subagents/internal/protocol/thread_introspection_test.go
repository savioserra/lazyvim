package protocol_test

import (
	"testing"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"google.golang.org/protobuf/proto"
)

func TestThreadSettlementIdentityRoundTripsAdditively(t *testing.T) {
	original := &subagentsv1.Envelope{Payload: &subagentsv1.Envelope_BridgeDeliveryAckRequest{BridgeDeliveryAckRequest: &subagentsv1.BridgeDeliveryAckRequest{
		AgentId: "agent", Sequence: 9, DedupeId: "dedupe", Delivered: true,
		ThreadId: "thread-opaque", SchedulerEpoch: 3, ActiveLease: 4, ThreadTurn: 5,
		BridgeRunCounter: 6, AgentEndObserved: true, AgentSettledObserved: true,
	}}}
	encoded, err := proto.Marshal(original)
	if err != nil {
		t.Fatal(err)
	}
	var decoded subagentsv1.Envelope
	if err := proto.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	ack := decoded.GetBridgeDeliveryAckRequest()
	if ack.GetThreadId() != "thread-opaque" || ack.GetSchedulerEpoch() != 3 || ack.GetActiveLease() != 4 || ack.GetThreadTurn() != 5 || ack.GetBridgeRunCounter() != 6 || !ack.GetAgentEndObserved() || !ack.GetAgentSettledObserved() {
		t.Fatalf("thread settlement identity changed on the wire: %#v", ack)
	}
}

func TestLegacyBridgeDeliveryAndAckRemainDecodable(t *testing.T) {
	for _, original := range []*subagentsv1.Envelope{
		{Payload: &subagentsv1.Envelope_BridgePushFrame{BridgePushFrame: &subagentsv1.BridgePushFrame{Deliveries: []*subagentsv1.BridgeDelivery{{Sequence: 1, DedupeId: "legacy"}}}}},
		{Payload: &subagentsv1.Envelope_BridgeDeliveryAckRequest{BridgeDeliveryAckRequest: &subagentsv1.BridgeDeliveryAckRequest{Sequence: 1, DedupeId: "legacy", Delivered: true}}},
	} {
		encoded, err := proto.Marshal(original)
		if err != nil {
			t.Fatal(err)
		}
		var decoded subagentsv1.Envelope
		if err := proto.Unmarshal(encoded, &decoded); err != nil {
			t.Fatal(err)
		}
		if !proto.Equal(original, &decoded) {
			t.Fatalf("legacy additive protocol changed: %v != %v", original, &decoded)
		}
	}
}
