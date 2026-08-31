package protocol_test

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/protocol"
)

func fixtureEnvelope() *subagentsv1.Envelope {
	return &subagentsv1.Envelope{
		ProtocolMajor: 1, SessionId: "session-fixture", GenerationId: "generation-fixture", RequestId: "request-fixture",
		DeadlineUnixMillis: 1893456000000, Sequence: 7, CallerIdentity: "caller-fixture",
		Payload: &subagentsv1.Envelope_HealthRequest{HealthRequest: &subagentsv1.HealthRequest{}},
	}
}

func hostedFixtureEnvelope() *subagentsv1.Envelope {
	return &subagentsv1.Envelope{
		ProtocolMajor: 1, ProtocolMinor: 1, SessionId: "bridge-session-fixture", GenerationId: "bridge-generation-fixture", RequestId: "bridge-request-fixture",
		DeadlineUnixMillis: 1893456001234, Sequence: 19, CallerIdentity: "hosted:agent-fixture", AgentHandle: "opaque-fenced-handle", SessionCredential: []byte{1, 2, 3, 4}, AgentFence: 23,
		Payload: &subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_ASK, Target: "agent-target", BoundedPayload: []byte("bounded"), DedupeId: "dedupe-fixture", HopLimit: 8, ChainId: "chain-fixture", SourceMutationSequence: 73}},
	}
}

// bridgePushFixtureEnvelope is the golden shape of a pushed prompt delivery:
// every field a hosted bridge acknowledgement must echo, including the
// opaque source scope token and completion key.
func bridgePushFixtureEnvelope() *subagentsv1.Envelope {
	return &subagentsv1.Envelope{
		ProtocolMajor: 1, ProtocolMinor: 1, SessionId: "bridge-session-fixture", GenerationId: "bridge-generation-fixture", RequestId: "bridge-push-fixture",
		DeadlineUnixMillis: 1893456001234, Sequence: 23, CallerIdentity: "hosted:agent-fixture", AgentHandle: "opaque-fenced-handle", AgentFence: 31,
		Payload: &subagentsv1.Envelope_BridgePushFrame{BridgePushFrame: &subagentsv1.BridgePushFrame{
			AgentId: "agent-target", LatestSequence: 9,
			Deliveries: []*subagentsv1.BridgeDelivery{{
				Sequence: 9, SourceAgentId: "hosted:agent-fixture", TargetAgentId: "agent-target", RequestId: "request-9", DeadlineUnixMillis: 1893456005678,
				DedupeId: "dedupe-9", HopLimit: 7, BoundedPayload: []byte("wake up"), Kind: subagentsv1.BridgeDelivery_KIND_PROMPT, ChainId: "chain-9",
				SourceScope: "opaque-scope-token-9", CompletionKey: "agent-target:9:hosted:agent-fixture:request-9:dedupe-9:chain-9:1",
			}},
		}},
	}
}

func TestDeterministicGoldenFrame(t *testing.T) {
	var frame bytes.Buffer
	if err := protocol.WriteEnvelope(&frame, fixtureEnvelope()); err != nil {
		t.Fatal(err)
	}
	goldenPath := filepath.Join("..", "..", "testdata", "golden", "health-frame.hex")
	golden, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(frame.Bytes()) != strings.TrimSpace(string(golden)) {
		t.Fatal("Go encoding differs from the checked-in Go/TypeScript golden frame")
	}
	decoded, err := protocol.ReadEnvelope(bytes.NewReader(frame.Bytes()))
	if err != nil || decoded.RequestId != "request-fixture" {
		t.Fatalf("golden did not round trip: %#v %v", decoded, err)
	}
}

func TestHostedBridgeGoldenFrame(t *testing.T) {
	var frame bytes.Buffer
	if err := protocol.WriteEnvelope(&frame, hostedFixtureEnvelope()); err != nil {
		t.Fatal(err)
	}
	golden, err := os.ReadFile(filepath.Join("..", "..", "testdata", "golden", "hosted-bridge-frame.hex"))
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(frame.Bytes()) != strings.TrimSpace(string(golden)) {
		t.Fatal("Go hosted bridge encoding differs from the checked-in TypeScript golden frame")
	}
	decoded, err := protocol.ReadEnvelope(bytes.NewReader(frame.Bytes()))
	if err != nil || decoded.GetActorMessageRequest().GetDedupeId() != "dedupe-fixture" || decoded.GetAgentFence() != 23 {
		t.Fatalf("hosted bridge golden did not round trip: %#v %v", decoded, err)
	}
}

func TestBridgePushDeliveryGoldenFrame(t *testing.T) {
	var frame bytes.Buffer
	if err := protocol.WriteEnvelope(&frame, bridgePushFixtureEnvelope()); err != nil {
		t.Fatal(err)
	}
	golden, err := os.ReadFile(filepath.Join("..", "..", "testdata", "golden", "bridge-push-frame.hex"))
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(frame.Bytes()) != strings.TrimSpace(string(golden)) {
		t.Fatal("Go bridge push encoding differs from the checked-in TypeScript golden frame")
	}
	decoded, err := protocol.ReadEnvelope(bytes.NewReader(frame.Bytes()))
	push := decoded.GetBridgePushFrame()
	if err != nil || len(push.GetDeliveries()) != 1 || push.GetDeliveries()[0].GetSourceScope() == "" || push.GetDeliveries()[0].GetCompletionKey() == "" {
		t.Fatalf("bridge push golden did not round trip with acknowledgement identity: %#v %v", decoded, err)
	}
}

func TestFrameLimitsTruncationAndUnknownVersions(t *testing.T) {
	t.Run("oversize", func(t *testing.T) {
		var prefix [4]byte
		binary.BigEndian.PutUint32(prefix[:], protocol.MaxFrameSize+1)
		_, err := protocol.ReadEnvelope(bytes.NewReader(prefix[:]))
		if !errors.Is(err, protocol.ErrFrameTooLarge) {
			t.Fatalf("got %v", err)
		}
	})
	t.Run("truncated prefix", func(t *testing.T) {
		_, err := protocol.ReadEnvelope(bytes.NewReader([]byte{0, 0}))
		if !errors.Is(err, io.ErrUnexpectedEOF) {
			t.Fatalf("got %v", err)
		}
	})
	t.Run("truncated payload", func(t *testing.T) {
		_, err := protocol.ReadEnvelope(bytes.NewReader([]byte{0, 0, 0, 4, 8}))
		if !errors.Is(err, io.ErrUnexpectedEOF) {
			t.Fatalf("got %v", err)
		}
	})
	t.Run("unknown major", func(t *testing.T) {
		envelope := fixtureEnvelope()
		envelope.ProtocolMajor = 99
		var frame bytes.Buffer
		if err := protocol.WriteEnvelope(&frame, envelope); err != nil {
			t.Fatal(err)
		}
		_, err := protocol.ReadEnvelope(&frame)
		if !errors.Is(err, protocol.ErrUnsupportedVersion) {
			t.Fatalf("got %v", err)
		}
	})
	t.Run("unknown fields survive decode policy", func(t *testing.T) {
		var frame bytes.Buffer
		if err := protocol.WriteEnvelope(&frame, fixtureEnvelope()); err != nil {
			t.Fatal(err)
		}
		payload := append([]byte(nil), frame.Bytes()[4:]...)
		payload = append(payload, 0xf8, 0x07, 0x01) // unknown field 127, varint 1
		var rebuilt bytes.Buffer
		_ = binary.Write(&rebuilt, binary.BigEndian, uint32(len(payload)))
		rebuilt.Write(payload)
		if _, err := protocol.ReadEnvelope(&rebuilt); err != nil {
			t.Fatalf("minor-compatible unknown field rejected: %v", err)
		}
	})
}
