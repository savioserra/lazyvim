package service_test

import (
	"context"
	"strings"
	"testing"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/service"
)

type hostedBridgeHarness struct {
	session                      application.OpenSession
	credential                   []byte
	runtimeID, piSession, handle string
	fence                        uint64
}

func (b hostedBridgeHarness) envelope(payload any, requestID, handle string, fence uint64) *subagentsv1.Envelope {
	envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, SessionId: b.session.SessionID, GenerationId: b.session.GenerationID, CallerIdentity: b.session.Caller, SessionCredential: b.credential, RequestId: requestID, DeadlineUnixMillis: time.Now().Add(3 * time.Second).UnixMilli(), AgentHandle: handle, AgentFence: fence}
	switch value := payload.(type) {
	case *subagentsv1.Envelope_AttachRequest:
		envelope.Payload = value
	case *subagentsv1.Envelope_BridgeConnectRequest:
		envelope.Payload = value
	case *subagentsv1.Envelope_BridgeLifecycleRequest:
		envelope.Payload = value
	case *subagentsv1.Envelope_BridgePollRequest:
		envelope.Payload = value
	case *subagentsv1.Envelope_BridgeDeliveryAckRequest:
		envelope.Payload = value
	case *subagentsv1.Envelope_ActorMessageRequest:
		envelope.Payload = value
	default:
		panic("unsupported hosted bridge test envelope")
	}
	return envelope
}

func TestHostedActorCanTellAndAskAnotherHostedActorThroughActorMessageRequest(t *testing.T) {
	path := privateTempDir(t) + "/control.sock"
	daemon, err := service.Start(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})

	register := func(agentID, runtimeID, piSession, ch string) hostedBridgeHarness {
		binding := application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, Lifetime: application.HostedPiLifetimeGlobalAgent, TmuxOwnership: application.HostedPiTmuxOwnershipExactSession, ControlBoundary: application.HostedPiControlDocumentedBridgeOnly, VisualizationBoundary: application.HostedPiVisualizationTmuxAttach, RuntimeID: runtimeID, Incarnation: 1}
		process := &deterministicProcess{binding: binding, exit: make(chan error, 1)}
		registration := application.RegisterAgent{AgentID: agentID, AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: runtimeID}, HostedPiRuntime: binding, AllowedCapability: []string{"observe", "hosted_bridge", "send", "ask", "control_abort", "control_shutdown"}, PhaseTwoOwned: true, Retention: "explicit", Recovery: "owned-binding-v1", Runtime: deterministicRuntime{process}, IntrospectionRunner: &completedIntrospectionRunner{}, LaunchSpec: application.HostedPiLaunchSpec{AgentID: agentID, RuntimeID: runtimeID, Incarnation: 1}}
		if err := daemon.RegisterAgent(context.Background(), registration); err != nil {
			t.Fatal(err)
		}
		credential := []byte(strings.Repeat(ch, 32))
		session := application.OpenSession{SessionID: "session-" + agentID, GenerationID: "generation-" + agentID, Caller: "hosted:" + agentID, Credential: credential, Capabilities: []string{"observe", "hosted_bridge", "send", "ask", "control_abort", "control_shutdown"}, ExpiresAt: time.Now().Add(time.Hour)}
		if err := daemon.OpenSession(context.Background(), session); err != nil {
			t.Fatal(err)
		}
		b := hostedBridgeHarness{session: session, credential: credential, runtimeID: runtimeID, piSession: piSession}
		connect := request(t, path, b.envelope(&subagentsv1.Envelope_BridgeConnectRequest{BridgeConnectRequest: &subagentsv1.BridgeConnectRequest{AgentId: agentID, RuntimeId: runtimeID, Incarnation: 1, PiSessionId: piSession}}, "connect-"+agentID, "", 0)).GetBridgeConnectResponse()
		if !connect.Accepted || connect.AgentHandle == "" || connect.Fence == 0 {
			t.Fatalf("connect %s: %#v", agentID, connect)
		}
		b.handle, b.fence = connect.AgentHandle, connect.Fence
		for _, event := range []subagentsv1.BridgeLifecycleRequest_Event{subagentsv1.BridgeLifecycleRequest_EVENT_SESSION_START, subagentsv1.BridgeLifecycleRequest_EVENT_READY} {
			if got := request(t, path, b.envelope(&subagentsv1.Envelope_BridgeLifecycleRequest{BridgeLifecycleRequest: &subagentsv1.BridgeLifecycleRequest{AgentId: agentID, RuntimeId: runtimeID, Incarnation: 1, Event: event}}, "life-"+agentID+event.String(), b.handle, b.fence)).GetBridgeLifecycleResponse(); !got.Accepted {
				t.Fatalf("ready %s: %#v", agentID, got)
			}
		}
		return b
	}
	a := register("alpha", "runtime-alpha", "pi-alpha", "a")
	b := register("bravo", "runtime-bravo", "pi-bravo", "b")

	attach := request(t, path, a.envelope(&subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: "bravo", RequestedCapabilities: []string{"observe", "send", "ask"}}}, "alpha-attach-bravo", "", 0)).GetAttachResponse()
	if attach.AgentHandle == "" || attach.Fence == 0 {
		t.Fatalf("alpha attach to bravo rejected: %#v", attach)
	}

	tell := request(t, path, a.envelope(&subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_TELL, Target: "bravo", BoundedPayload: []byte("hello bravo"), DedupeId: "alpha-tell-bravo", ChainId: "alpha-chain-tell", HopLimit: 8, SourceMutationSequence: 1}}, "alpha-tell", attach.AgentHandle, attach.Fence)).GetActorMessageResponse()
	if tell == nil || !tell.Accepted {
		t.Fatalf("hosted alpha->bravo tell rejected: %#v", tell)
	}

	ask := request(t, path, a.envelope(&subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_ASK, Target: "bravo", BoundedPayload: []byte("question bravo"), DedupeId: "alpha-ask-bravo", ChainId: "alpha-chain-ask", HopLimit: 8, SourceMutationSequence: 2}}, "alpha-ask", attach.AgentHandle, attach.Fence)).GetActorMessageResponse()
	if ask == nil || !ask.Accepted || ask.Completed {
		t.Fatalf("hosted alpha->bravo ask admission wrong: %#v", ask)
	}

	var deliveries []*subagentsv1.BridgeDelivery
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		poll := request(t, path, b.envelope(&subagentsv1.Envelope_BridgePollRequest{BridgePollRequest: &subagentsv1.BridgePollRequest{AgentId: "bravo", MaxItems: 64}}, "bravo-poll", b.handle, b.fence)).GetBridgePollResponse()
		deliveries = poll.Deliveries
		if len(deliveries) >= 2 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if len(deliveries) < 2 {
		t.Fatalf("bravo did not receive alpha tell and ask: %#v", deliveries)
	}
	for _, d := range deliveries {
		var result []byte
		if d.Kind == subagentsv1.BridgeDelivery_KIND_PROMPT {
			result = []byte("answer from bravo")
		}
		ack := request(t, path, b.envelope(&subagentsv1.Envelope_BridgeDeliveryAckRequest{BridgeDeliveryAckRequest: identityBridgeAck("bravo", b.runtimeID, b.piSession, 1, d, true, result)}, "ack-"+d.DedupeId, b.handle, b.fence)).GetBridgeDeliveryAckResponse()
		if ack == nil || !ack.Accepted {
			t.Fatalf("bravo ack rejected for %s: %#v", d.DedupeId, ack)
		}
	}

	var completed *subagentsv1.ActorMessageResponse
	deadline = time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		completed = request(t, path, a.envelope(&subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_ASK, Target: "bravo", BoundedPayload: []byte("question bravo"), DedupeId: "alpha-ask-bravo", ChainId: "alpha-chain-ask", HopLimit: 8, SourceMutationSequence: 2}}, "alpha-ask-retry", attach.AgentHandle, attach.Fence)).GetActorMessageResponse()
		if completed != nil && completed.Accepted && completed.Completed {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if completed == nil || !completed.Accepted || !completed.Completed || string(completed.BoundedResult) != "answer from bravo" {
		t.Fatalf("alpha did not observe exactly completed ask retry: %#v", completed)
	}
}
