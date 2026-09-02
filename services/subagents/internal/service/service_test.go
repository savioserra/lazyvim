package service_test

import (
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/protocol"
	"github.com/savioserra/lazyvim/services/subagents/internal/service"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
)

func testRegistration(agentID string, capabilities ...string) application.RegisterAgent {
	return application.RegisterAgent{AgentID: agentID, AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "observed-run"}, HostedPiRuntime: application.InactiveHostedPiRuntimeBinding(), AllowedCapability: capabilities, Retention: "explicit", Recovery: "metadata-only"}
}

func TestHealthReadinessAndCoordinatedShutdown(t *testing.T) {
	path := filepath.Join(privateTempDir(t), "runtime", "control.sock")
	daemon, err := service.Start(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	health, err := daemon.Health(context.Background())
	if err != nil || !health.Live || !health.Ready || health.Status != "ready" {
		t.Fatalf("daemon was not ready: %#v %v", health, err)
	}
	response := request(t, path, &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: "health", DeadlineUnixMillis: time.Now().Add(time.Second).UnixMilli(), Payload: &subagentsv1.Envelope_HealthRequest{HealthRequest: &subagentsv1.HealthRequest{}}})
	if !response.GetHealthResponse().Ready {
		t.Fatalf("socket health was not ready: %#v", response)
	}
	idle, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer idle.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := daemon.Stop(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Fatalf("shutdown left socket behind: %v", err)
	}
}

func TestPublicAgentListResolveSanitizesRuntimeIdentityAndUsesDisplayMetadata(t *testing.T) {
	path := filepath.Join(privateTempDir(t), "runtime", "control.sock")
	daemon, err := service.Start(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	registration := testRegistration("beta", "observe")
	registration.Role = "QA"
	registration.DisplayName = "spoofed-manager"
	if err := daemon.RegisterAgent(context.Background(), registration); err != nil {
		t.Fatal(err)
	}
	credential := []byte(strings.Repeat("s", 32))
	if err := daemon.OpenSession(context.Background(), application.OpenSession{SessionID: "public-session", GenerationID: "public-generation", Caller: "caller", Credential: credential, Capabilities: []string{"observe"}, ExpiresAt: time.Now().Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	envelope := authenticatedEnvelope("public-session", "public-generation", "caller", credential, "list", 1)
	envelope.Payload = &subagentsv1.Envelope_ListAgentsRequest{ListAgentsRequest: &subagentsv1.ListAgentsRequest{}}
	listed := request(t, path, envelope).GetListAgentsResponse().GetAgents()
	if len(listed) != 1 || listed[0].GetRole() != "QA" || listed[0].GetDisplayName() != "spoofed-manager" {
		t.Fatalf("public metadata was not preserved: %#v", listed)
	}
	encoded := protojson.MarshalOptions{}.Format(listed[0])
	for _, forbidden := range []string{"hostedRuntimeId", "tmuxSessionId", "panePid", "attachTarget", "sessionId", "handle", "fence"} {
		if strings.Contains(encoded, forbidden) {
			t.Fatalf("public list exposed raw runtime identity %q in %s", forbidden, encoded)
		}
	}
}

func TestProtocolDedupeReplayCollisionAndGenerationIsolation(t *testing.T) {
	path := filepath.Join(privateTempDir(t), "runtime", "control.sock")
	daemon, err := service.Start(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	if err := daemon.RegisterAgent(context.Background(), testRegistration("stable-agent", "observe", "steer")); err != nil {
		t.Fatal(err)
	}
	credentialOne := []byte(strings.Repeat("a", 32))
	credentialTwo := []byte(strings.Repeat("b", 32))
	for _, session := range []application.OpenSession{
		{SessionID: "one", GenerationID: "generation-one", Caller: "caller-one", Credential: credentialOne, Capabilities: []string{"observe", "steer"}, ExpiresAt: time.Now().Add(time.Hour)},
		{SessionID: "two", GenerationID: "generation-two", Caller: "caller-two", Credential: credentialTwo, Capabilities: []string{"observe", "steer"}, ExpiresAt: time.Now().Add(time.Hour)},
	} {
		if err := daemon.OpenSession(context.Background(), session); err != nil {
			t.Fatal(err)
		}
	}
	if err := daemon.OpenSession(context.Background(), application.OpenSession{SessionID: "equal-generation-session", GenerationID: "generation-one", Caller: "caller-one", Credential: credentialOne, Capabilities: []string{"observe"}, ExpiresAt: time.Now().Add(time.Hour)}); err == nil {
		t.Fatal("equal generation was accepted for a different session")
	}

	connection, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	attachRequest := authenticatedEnvelope("one", "generation-one", "caller-one", credentialOne, "attach-id", 1)
	attachRequest.Payload = &subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: "stable-agent", RequestedCapabilities: []string{"observe"}}}
	first := roundTrip(t, connection, attachRequest)
	replayed := roundTrip(t, connection, attachRequest)
	if first.GetAttachResponse().GetStatus() != subagentsv1.AttachResponse_STATUS_COMPLETED || replayed.GetAttachResponse().GetAgentHandle() != first.GetAttachResponse().GetAgentHandle() || replayed.GetAttachResponse().GetFence() != first.GetAttachResponse().GetFence() {
		t.Fatalf("attach replay was not stable: first=%#v replay=%#v", first, replayed)
	}

	reattach := authenticatedEnvelope("one", "generation-one", "caller-one", credentialOne, "reattach-id", 2)
	reattach.AgentHandle = first.GetAttachResponse().GetAgentHandle()
	reattach.Payload = &subagentsv1.Envelope_ReattachRequest{ReattachRequest: &subagentsv1.ReattachRequest{AgentId: "stable-agent", PreviousFence: first.GetAttachResponse().GetFence()}}
	second := roundTrip(t, connection, reattach)
	replayedSecond := roundTrip(t, connection, reattach)
	if second.GetAttachResponse().GetStatus() != subagentsv1.AttachResponse_STATUS_COMPLETED || replayedSecond.GetAttachResponse().GetAgentHandle() != second.GetAttachResponse().GetAgentHandle() {
		t.Fatalf("reattach replay rotated state: second=%#v replay=%#v", second, replayedSecond)
	}
	collisionSequence := cloneEnvelope(reattach)
	collisionSequence.GetReattachRequest().PreviousFence++
	if result := roundTrip(t, connection, collisionSequence); !strings.Contains(result.GetProtocolError().GetMessage(), "sequence payload collision") {
		t.Fatalf("same sequence accepted different payload: %#v", result)
	}

	cross := authenticatedEnvelope("two", "generation-two", "caller-two", credentialTwo, "attach-id", 1)
	cross.Payload = &subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: "stable-agent", RequestedCapabilities: []string{"observe"}}}
	crossResult := request(t, path, cross)
	if crossResult.GetAttachResponse().GetStatus() != subagentsv1.AttachResponse_STATUS_COMPLETED || crossResult.GetAttachResponse().GetAgentHandle() == first.GetAttachResponse().GetAgentHandle() {
		t.Fatalf("cross-session request ID collided: %#v", crossResult)
	}

	digestCollision := authenticatedEnvelope("two", "generation-two", "caller-two", credentialTwo, "attach-id", 1)
	digestCollision.Payload = &subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: "stable-agent", RequestedCapabilities: []string{"observe", "steer"}}}
	if result := request(t, path, digestCollision); !strings.Contains(result.GetProtocolError().GetMessage(), "payload collision") {
		t.Fatalf("same request ID accepted different canonical payload: %#v", result)
	}

	activeCrossConnectionReplay := request(t, path, attachRequest)
	if activeCrossConnectionReplay.GetAttachResponse().GetAgentHandle() != first.GetAttachResponse().GetAgentHandle() {
		t.Fatalf("cross-connection replay was not stable: %#v", activeCrossConnectionReplay)
	}
	if err := daemon.CloseSession(context.Background(), "one"); err != nil {
		t.Fatal(err)
	}
	sameConnectionStale := roundTrip(t, connection, attachRequest)
	if sameConnectionStale.GetProtocolError().GetCode() != subagentsv1.ProtocolError_CODE_SESSION_MISMATCH {
		t.Fatalf("same-connection replay bypassed revoked authorization: %#v", sameConnectionStale)
	}
	stale := request(t, path, attachRequest)
	if stale.GetAttachResponse().GetStatus() != subagentsv1.AttachResponse_STATUS_REJECTED {
		t.Fatalf("stale generation obtained cached attach: %#v", stale)
	}
	if err := daemon.OpenSession(context.Background(), application.OpenSession{SessionID: "one", GenerationID: "generation-three", Caller: "caller-one", Credential: credentialOne, Capabilities: []string{"observe"}, ExpiresAt: time.Now().Add(time.Hour)}); err == nil {
		t.Fatal("reused a closed session identity")
	}
	if err := daemon.OpenSession(context.Background(), application.OpenSession{SessionID: "three", GenerationID: "generation-one", Caller: "caller-one", Credential: credentialOne, Capabilities: []string{"observe"}, ExpiresAt: time.Now().Add(time.Hour)}); err == nil {
		t.Fatal("reused a generation identity in a different session")
	}
}

func TestMutationResultEvictionFailsClosed(t *testing.T) {
	path := filepath.Join(privateTempDir(t), "runtime", "control.sock")
	daemon, err := service.Start(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	if err := daemon.RegisterAgent(context.Background(), testRegistration("eviction-agent", "observe")); err != nil {
		t.Fatal(err)
	}
	credential := []byte(strings.Repeat("x", 32))
	if err := daemon.OpenSession(context.Background(), application.OpenSession{SessionID: "eviction-session", GenerationID: "eviction-generation", Caller: "caller", Credential: credential, Capabilities: []string{"observe"}, ExpiresAt: time.Now().Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	first := authenticatedEnvelope("eviction-session", "eviction-generation", "caller", credential, "original", 1)
	first.Payload = &subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: "eviction-agent", RequestedCapabilities: []string{"observe"}}}
	if response := request(t, path, first); response.GetAttachResponse().GetStatus() != subagentsv1.AttachResponse_STATUS_COMPLETED {
		t.Fatalf("initial attach failed: %#v", response)
	}
	for index := 0; index < 1024; index++ {
		next := authenticatedEnvelope("eviction-session", "eviction-generation", "caller", credential, fmt.Sprintf("fill-%d", index), 1)
		next.Payload = &subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: "eviction-agent", RequestedCapabilities: []string{"observe"}}}
		if response := request(t, path, next); response.GetAttachResponse().GetStatus() != subagentsv1.AttachResponse_STATUS_COMPLETED {
			t.Fatalf("fill attach %d failed: %#v", index, response)
		}
	}
	forgotten := request(t, path, first)
	if !strings.Contains(forgotten.GetProtocolError().GetMessage(), "outside the retained") {
		t.Fatalf("evicted mutation executed again: %#v", forgotten)
	}
}

func TestSameConnectionReplayRevalidatesAbsoluteDeadline(t *testing.T) {
	path := filepath.Join(privateTempDir(t), "runtime", "control.sock")
	daemon, err := service.Start(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	connection, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	request := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: "expiring-health", DeadlineUnixMillis: time.Now().Add(100 * time.Millisecond).UnixMilli(), Payload: &subagentsv1.Envelope_HealthRequest{HealthRequest: &subagentsv1.HealthRequest{}}}
	if response := roundTrip(t, connection, request); !response.GetHealthResponse().GetReady() {
		t.Fatalf("initial request failed before deadline: %#v", response)
	}
	time.Sleep(150 * time.Millisecond)
	if response := roundTrip(t, connection, request); response.GetProtocolError().GetCode() != subagentsv1.ProtocolError_CODE_DEADLINE_EXCEEDED {
		t.Fatalf("cached replay bypassed absolute deadline: %#v", response)
	}
}

func TestPerConnectionReplayWindowAndSequenceAdvanceBounds(t *testing.T) {
	path := filepath.Join(privateTempDir(t), "runtime", "control.sock")
	daemon, err := service.Start(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	connection, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	first := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: "health-1", DeadlineUnixMillis: time.Now().Add(time.Minute).UnixMilli(), Payload: &subagentsv1.Envelope_HealthRequest{HealthRequest: &subagentsv1.HealthRequest{}}}
	if !roundTrip(t, connection, first).GetHealthResponse().GetReady() {
		t.Fatal("initial health failed")
	}
	for sequence := uint64(2); sequence <= 257; sequence++ {
		envelope := cloneEnvelope(first)
		envelope.Sequence = sequence
		envelope.RequestId = "health-" + time.Unix(int64(sequence), 0).Format("150405")
		if !roundTrip(t, connection, envelope).GetHealthResponse().GetReady() {
			t.Fatalf("sequence %d failed", sequence)
		}
	}
	if result := roundTrip(t, connection, first); !strings.Contains(result.GetProtocolError().GetMessage(), "outside the bounded replay window") {
		t.Fatalf("old sequence remained replayable: %#v", result)
	}

	other, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	jump := cloneEnvelope(first)
	jump.Sequence = 1025
	if result := roundTrip(t, other, jump); !strings.Contains(result.GetProtocolError().GetMessage(), "advance exceeds bound") {
		t.Fatalf("unbounded sequence jump accepted: %#v", result)
	}
	zero := cloneEnvelope(first)
	zero.Sequence = 0
	if result := roundTrip(t, other, zero); !strings.Contains(result.GetProtocolError().GetMessage(), "nonzero") {
		t.Fatalf("zero sequence accepted: %#v", result)
	}
}

func TestAdmissionRejectsConnectionBeyondBound(t *testing.T) {
	path := filepath.Join(privateTempDir(t), "runtime", "control.sock")
	daemon, err := service.Start(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	connections := make([]net.Conn, 0, 32)
	for i := 0; i < 32; i++ {
		connection, err := net.Dial("unix", path)
		if err != nil {
			t.Fatal(err)
		}
		connections = append(connections, connection)
	}
	defer func() {
		for _, connection := range connections {
			_ = connection.Close()
		}
	}()
	time.Sleep(50 * time.Millisecond)
	overflow, err := net.Dial("unix", path)
	if err != nil {
		return
	}
	defer overflow.Close()
	_ = overflow.SetDeadline(time.Now().Add(time.Second))
	envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: "overflow", DeadlineUnixMillis: time.Now().Add(time.Second).UnixMilli(), Payload: &subagentsv1.Envelope_HealthRequest{HealthRequest: &subagentsv1.HealthRequest{}}}
	if err := protocol.WriteEnvelope(overflow, envelope); err == nil {
		if _, err := protocol.ReadEnvelope(overflow); err == nil {
			t.Fatal("connection beyond admission bound was processed")
		}
	}
}

func privateTempDir(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	return root
}

func authenticatedEnvelope(session, generation, caller string, credential []byte, requestID string, sequence uint64) *subagentsv1.Envelope {
	return &subagentsv1.Envelope{ProtocolMajor: 1, SessionId: session, GenerationId: generation, CallerIdentity: caller, SessionCredential: credential, RequestId: requestID, Sequence: sequence, DeadlineUnixMillis: time.Now().Add(time.Minute).UnixMilli()}
}

func request(t *testing.T, path string, envelope *subagentsv1.Envelope) *subagentsv1.Envelope {
	t.Helper()
	connection, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	return roundTrip(t, connection, envelope)
}
func roundTrip(t *testing.T, connection net.Conn, envelope *subagentsv1.Envelope) *subagentsv1.Envelope {
	t.Helper()
	if err := protocol.WriteEnvelope(connection, envelope); err != nil {
		t.Fatal(err)
	}
	response, err := protocol.ReadEnvelope(connection)
	if err != nil {
		t.Fatal(err)
	}
	return response
}
func frontendCompletionAck(frame *subagentsv1.Envelope) *subagentsv1.FrontendCompletionAckRequest {
	reply := frame.GetActorMessageReplyFrame()
	if reply == nil {
		return nil
	}
	return &subagentsv1.FrontendCompletionAckRequest{CompletionKey: reply.CompletionKey, FrameSequence: frame.Sequence, OriginalRequestId: reply.OriginalRequestId, DedupeId: reply.DedupeId, ChainId: reply.ChainId, SourceMutationSequence: reply.SourceMutationSequence}
}

func cloneEnvelope(envelope *subagentsv1.Envelope) *subagentsv1.Envelope {
	return proto.Clone(envelope).(*subagentsv1.Envelope)
}
