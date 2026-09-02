package service

import (
	"context"
	"net"
	"testing"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/protocol"
)

func TestRegularTerminalWebSocketPushOccursOnlyAfterTargetCommit(t *testing.T) {
	daemon, stop := terminalIdentityHarness(t)
	defer stop()
	opened := terminalIdentityOpen(t, daemon, "regular-push")
	if !opened.Accepted {
		t.Fatalf("terminal open failed: %#v", opened)
	}
	connection, err := net.Dial("unix", daemon.socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	register := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: "register-regular-push", DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli(), SessionId: opened.SessionId, GenerationId: opened.GenerationId, CallerIdentity: opened.CallerIdentity, SessionCredential: opened.SessionCredential, Payload: &subagentsv1.Envelope_ListAgentsRequest{ListAgentsRequest: &subagentsv1.ListAgentsRequest{}}}
	if err := protocol.WriteEnvelope(connection, register); err != nil {
		t.Fatal(err)
	}
	if response, err := protocol.ReadEnvelope(connection); err != nil || response.RequestId != register.RequestId || response.GetListAgentsResponse() == nil {
		t.Fatalf("regular socket registration failed: %#v %v", response, err)
	}
	if err := connection.SetReadDeadline(time.Now().Add(75 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	if frame, err := protocol.ReadEnvelope(connection); err == nil && frame.GetBridgePushFrame() != nil {
		t.Fatalf("regular delivery pushed before target commit: %#v", frame.GetBridgePushFrame())
	}
	if err := connection.SetReadDeadline(time.Time{}); err != nil {
		t.Fatal(err)
	}

	ctx := context.Background()
	value, err := daemon.system.NoSender().Ask(ctx, daemon.agentRegistry, &application.ResolveAgentControl{AgentID: opened.CallerIdentity}, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	target := value.(*application.AgentControlPID)
	if !target.Found || target.PID == nil {
		t.Fatal("terminal target actor unavailable")
	}
	binding := application.InactiveHostedPiRuntimeBinding()
	source, err := daemon.system.Spawn(ctx, "regular-push-source", actors.NewAgentActor(&application.RegisterAgent{AgentID: "regular-push-source", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "regular-push-source"}, HostedPiRuntime: binding, AllowedCapability: []string{"observe", "send"}, Retention: "bounded", Recovery: "terminal-reattach"}))
	if err != nil {
		t.Fatal(err)
	}
	receipt := make(chan application.BridgeIntentResult, 1)
	if err := daemon.system.NoSender().Tell(ctx, source, &application.SendActorTask{TargetPID: target.PID, TargetPeer: application.CommunicationPeer{StableID: opened.CallerIdentity, DisplayName: "Terminal One", Role: "Coordinator"}, RequestID: "regular-push-request", DedupeID: "regular-push-dedupe", ChainID: "regular-push-chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(5 * time.Second), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: []byte("committed report"), Receipt: receipt}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-receipt:
		if !result.Accepted {
			t.Fatalf("source admission failed: %#v", result)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("source admission timed out")
	}

	if err := connection.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	frame, err := protocol.ReadEnvelope(connection)
	if err != nil {
		t.Fatal("target commit did not trigger regular websocket push:", err)
	}
	push := frame.GetBridgePushFrame()
	if push == nil || len(push.Deliveries) != 1 || push.Deliveries[0].DedupeId != "regular-push-dedupe" || string(push.Deliveries[0].BoundedPayload) != "committed report" {
		t.Fatalf("post-commit regular push mismatch: %#v", frame)
	}
	if err := connection.SetReadDeadline(time.Now().Add(150 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	if duplicate, err := protocol.ReadEnvelope(connection); err == nil && duplicate.GetBridgePushFrame() != nil {
		t.Fatalf("target commit pushed regular delivery more than once: %#v", duplicate)
	}
}
