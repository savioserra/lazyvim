package service_test

import (
	"context"
	"strings"
	"testing"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/service"
	"google.golang.org/protobuf/proto"
)

type deterministicRuntime struct{ process *deterministicProcess }

func (r deterministicRuntime) Start(context.Context, application.HostedPiLaunchSpec) (application.HostedPiOwnedProcess, error) {
	return r.process, nil
}

type deterministicProcess struct {
	binding application.HostedPiRuntimeBinding
	exit    chan error
}

func (p *deterministicProcess) Binding() application.HostedPiRuntimeBinding { return p.binding }
func (p *deterministicProcess) Wait() error                                 { return <-p.exit }
func (p *deterministicProcess) Stop(context.Context) error {
	select {
	case p.exit <- nil:
	default:
	}
	return nil
}

func TestDeterministicHostedBridgeGatewayAndClientIndependence(t *testing.T) {
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

	binding := application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, Lifetime: application.HostedPiLifetimeGlobalAgent, TmuxOwnership: application.HostedPiTmuxOwnershipExactSession, ControlBoundary: application.HostedPiControlDocumentedBridgeOnly, VisualizationBoundary: application.HostedPiVisualizationTmuxAttach, RuntimeID: "runtime-one", Incarnation: 1}
	process := &deterministicProcess{binding: binding, exit: make(chan error, 1)}
	registration := application.RegisterAgent{AgentID: "agent-one", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: binding.RuntimeID}, HostedPiRuntime: binding, AllowedCapability: []string{"observe", "hosted_bridge", "send", "ask", "control_abort", "control_shutdown"}, PhaseTwoOwned: true, Retention: "explicit", Recovery: "owned-binding-v1", Runtime: deterministicRuntime{process}, LaunchSpec: application.HostedPiLaunchSpec{AgentID: "agent-one", RuntimeID: binding.RuntimeID, Incarnation: 1}}
	if err := daemon.RegisterAgent(context.Background(), registration); err != nil {
		t.Fatal(err)
	}

	credential := []byte(strings.Repeat("b", 32))
	bridgeSession := application.OpenSession{SessionID: "bridge-session", GenerationID: "bridge-generation", Caller: "hosted:agent-one", Credential: credential, Capabilities: []string{"observe", "hosted_bridge", "send", "ask"}, ExpiresAt: time.Now().Add(time.Hour)}
	if err := daemon.OpenSession(context.Background(), bridgeSession); err != nil {
		t.Fatal(err)
	}
	base := func(payload any) *subagentsv1.Envelope {
		envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, SessionId: bridgeSession.SessionID, GenerationId: bridgeSession.GenerationID, CallerIdentity: bridgeSession.Caller, SessionCredential: credential, RequestId: time.Now().String(), DeadlineUnixMillis: time.Now().Add(3 * time.Second).UnixMilli()}
		switch value := payload.(type) {
		case *subagentsv1.Envelope_BridgeConnectRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_BridgeLifecycleRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_ListAgentsRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_ResolveAgentRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_ActorMessageRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_SubscribeAgentRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_UnsubscribeAgentRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_BridgePollRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_BridgeDeliveryAckRequest:
			envelope.Payload = value
		default:
			t.Fatalf("unsupported test payload %T", payload)
		}
		return envelope
	}

	connect := request(t, path, base(&subagentsv1.Envelope_BridgeConnectRequest{BridgeConnectRequest: &subagentsv1.BridgeConnectRequest{AgentId: "agent-one", RuntimeId: "runtime-one", Incarnation: 1, PiSessionId: "pi-session"}}))
	connected := connect.GetBridgeConnectResponse()
	if !connected.Accepted || connected.AgentHandle == "" || connected.Fence == 0 {
		t.Fatalf("bridge connect failed: %#v", connect)
	}
	fenced := func(envelope *subagentsv1.Envelope) *subagentsv1.Envelope {
		envelope.AgentHandle, envelope.AgentFence = connected.AgentHandle, connected.Fence
		return envelope
	}
	for _, event := range []subagentsv1.BridgeLifecycleRequest_Event{subagentsv1.BridgeLifecycleRequest_EVENT_SESSION_START, subagentsv1.BridgeLifecycleRequest_EVENT_READY} {
		response := request(t, path, fenced(base(&subagentsv1.Envelope_BridgeLifecycleRequest{BridgeLifecycleRequest: &subagentsv1.BridgeLifecycleRequest{AgentId: "agent-one", RuntimeId: "runtime-one", Incarnation: 1, Event: event}})))
		if !response.GetBridgeLifecycleResponse().Accepted {
			t.Fatalf("lifecycle rejected: %#v", response)
		}
	}

	listed := request(t, path, base(&subagentsv1.Envelope_ListAgentsRequest{ListAgentsRequest: &subagentsv1.ListAgentsRequest{}}))
	if len(listed.GetListAgentsResponse().Agents) != 1 || !listed.GetListAgentsResponse().Agents[0].HostedPiRuntime.BridgeReady {
		t.Fatalf("ready hosted binding missing: %#v", listed)
	}
	resolved := request(t, path, base(&subagentsv1.Envelope_ResolveAgentRequest{ResolveAgentRequest: &subagentsv1.ResolveAgentRequest{AgentId: "agent"}}))
	if resolved.GetResolveAgentResponse().Agent.GetAgentId() != "agent-one" {
		t.Fatalf("prefix resolution failed: %#v", resolved)
	}
	fencedBase := func(payload any) *subagentsv1.Envelope { return fenced(base(payload)) }
	reconnected := request(t, path, base(&subagentsv1.Envelope_BridgeConnectRequest{BridgeConnectRequest: &subagentsv1.BridgeConnectRequest{AgentId: "agent-one", RuntimeId: "runtime-one", Incarnation: 1, PiSessionId: "pi-session"}})).GetBridgeConnectResponse()
	if !reconnected.Accepted || reconnected.AgentHandle != connected.AgentHandle || reconnected.Fence != connected.Fence {
		t.Fatal("same-ID reconnect rotated the bridge fence")
	}
	if request(t, path, base(&subagentsv1.Envelope_BridgeConnectRequest{BridgeConnectRequest: &subagentsv1.BridgeConnectRequest{AgentId: "agent-one", RuntimeId: "runtime-one", Incarnation: 1, PiSessionId: "foreign-pi-session"}})).GetBridgeConnectResponse().Accepted {
		t.Fatal("different Pi session replaced the bridge implicitly")
	}
	for _, unknown := range []subagentsv1.BridgeLifecycleRequest_Event{0, 6, 99, -1} {
		envelope := fencedBase(&subagentsv1.Envelope_BridgeLifecycleRequest{BridgeLifecycleRequest: &subagentsv1.BridgeLifecycleRequest{AgentId: "agent-one", RuntimeId: "runtime-one", Incarnation: 1, Event: unknown}})
		result := request(t, path, envelope)
		if result.GetProtocolError() == nil || result.GetBridgeLifecycleResponse() != nil {
			t.Fatalf("unknown generated lifecycle enum %d mutated or acknowledged: %#v", unknown, result)
		}
	}
	regularCredential := []byte(strings.Repeat("c", 32))
	clientSession := application.OpenSession{SessionID: "regular-client", GenerationID: "regular-generation", Caller: "client:regular", Credential: regularCredential, Capabilities: []string{"observe", "send", "ask", "prompt"}, ExpiresAt: time.Now().Add(time.Hour)}
	if err := daemon.OpenSession(context.Background(), clientSession); err != nil {
		t.Fatal(err)
	}
	clientBase := func(payload any, requestID string) *subagentsv1.Envelope {
		envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, SessionId: clientSession.SessionID, GenerationId: clientSession.GenerationID, CallerIdentity: clientSession.Caller, SessionCredential: regularCredential, RequestId: requestID, DeadlineUnixMillis: time.Now().Add(time.Second).UnixMilli()}
		switch value := payload.(type) {
		case *subagentsv1.Envelope_AttachRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_ActorMessageRequest:
			envelope.Payload = value
		default:
			t.Fatalf("unsupported regular-client test payload %T", payload)
		}
		return envelope
	}
	clientAttach := request(t, path, clientBase(&subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: "agent-one", RequestedCapabilities: []string{"observe", "send"}}}, "regular-attach")).GetAttachResponse()
	if clientAttach.AgentHandle == "" || clientAttach.Fence == 0 {
		t.Fatalf("regular client attach failed: %#v", clientAttach)
	}
	regularTell := clientBase(&subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_TELL, Target: "agent-one", BoundedPayload: []byte("regular-client-note"), DedupeId: "regular-client-tell", HopLimit: 8, ChainId: "regular-client-chain", SourceMutationSequence: 1}}, "regular-tell")
	regularTell.AgentHandle, regularTell.AgentFence = clientAttach.AgentHandle, clientAttach.Fence
	regularResponse := request(t, path, regularTell).GetActorMessageResponse()
	if !regularResponse.Accepted || regularResponse.Kind != "Tell" || regularResponse.Source.GetStableId() != "project-manager" || regularResponse.Target.GetDisplayName() != "agent-one" {
		t.Fatalf("regular client Tell was not admitted with authoritative peers/kind: %#v", regularResponse)
	}
	regularPoll := request(t, path, fencedBase(&subagentsv1.Envelope_BridgePollRequest{BridgePollRequest: &subagentsv1.BridgePollRequest{AgentId: "agent-one", MaxItems: 64}})).GetBridgePollResponse()
	var regularDelivery *subagentsv1.BridgeDelivery
	for _, delivery := range regularPoll.Deliveries {
		if delivery.DedupeId == "regular-client-tell" {
			regularDelivery = delivery
		}
	}
	if regularDelivery == nil || regularDelivery.Kind != subagentsv1.BridgeDelivery_KIND_NOTIFICATION || regularDelivery.Source.GetDisplayName() != "PROJECT MANAGER" || regularDelivery.Target.GetDisplayName() != "agent-one" {
		t.Fatalf("regular client Tell delivery lost authoritative source/target/kind: %#v", regularPoll.Deliveries)
	}
	regularAck := request(t, path, fencedBase(&subagentsv1.Envelope_BridgeDeliveryAckRequest{BridgeDeliveryAckRequest: &subagentsv1.BridgeDeliveryAckRequest{AgentId: "agent-one", Sequence: regularDelivery.Sequence, DedupeId: regularDelivery.DedupeId, Delivered: true}}))
	if !regularAck.GetBridgeDeliveryAckResponse().Accepted {
		t.Fatalf("regular client Tell ack rejected: %#v", regularAck)
	}
	for name, envelope := range map[string]*subagentsv1.Envelope{
		"unknown-mode": fencedBase(&subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: 99, Target: "agent-one", BoundedPayload: []byte("bad"), DedupeId: "bad-mode", HopLimit: 8, ChainId: "bad-mode-chain"}}),
		"empty-fence":  base(&subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_TELL, Target: "agent-one", BoundedPayload: []byte("bad"), DedupeId: "empty-fence", HopLimit: 8, ChainId: "empty-fence-chain"}}),
	} {
		response := request(t, path, envelope)
		if message := response.GetActorMessageResponse(); message != nil && message.Accepted {
			t.Fatalf("%s adversarial message was accepted", name)
		}
	}
	stale := fencedBase(&subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_TELL, Target: "agent-one", BoundedPayload: []byte("bad"), DedupeId: "stale", HopLimit: 8, ChainId: "stale-chain"}})
	stale.AgentFence++
	if request(t, path, stale).GetActorMessageResponse().Accepted {
		t.Fatal("stale target fence was accepted")
	}
	observeCredential := []byte(strings.Repeat("o", 32))
	observeSession := application.OpenSession{SessionID: "observe-only", GenerationID: "observe-generation", Caller: "hosted:observer", Credential: observeCredential, Capabilities: []string{"observe"}, ExpiresAt: time.Now().Add(time.Hour)}
	if err := daemon.OpenSession(context.Background(), observeSession); err != nil {
		t.Fatal(err)
	}
	observeAttempt := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, SessionId: observeSession.SessionID, GenerationId: observeSession.GenerationID, CallerIdentity: observeSession.Caller, SessionCredential: observeCredential, RequestId: "observe-as-send", DeadlineUnixMillis: time.Now().Add(time.Second).UnixMilli(), Payload: &subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_TELL, Target: "agent-one", BoundedPayload: []byte("denied"), DedupeId: "observe-denied", HopLimit: 8, ChainId: "observe-chain"}}}
	if message := request(t, path, observeAttempt).GetActorMessageResponse(); message != nil && message.Accepted {
		t.Fatal("observe-only session sent an ordinary message")
	}
	observeControl := proto.Clone(observeAttempt).(*subagentsv1.Envelope)
	observeControl.RequestId = "observe-as-control"
	observeControl.Payload = &subagentsv1.Envelope_ActorControlRequest{ActorControlRequest: &subagentsv1.ActorControlRequest{Intent: subagentsv1.ActorControlRequest_INTENT_ABORT, Target: "agent-one", DedupeId: "observe-control", HopLimit: 2, ChainId: "observe-control-chain"}}
	if message := request(t, path, observeControl).GetActorMessageResponse(); message != nil && message.Accepted {
		t.Fatal("observe-only session invoked typed control")
	}
	forgedCredential := []byte(strings.Repeat("f", 32))
	forgedSession := application.OpenSession{SessionID: "forged-source", GenerationID: "forged-generation", Caller: "human-forgery", Credential: forgedCredential, Capabilities: []string{"send"}, ExpiresAt: time.Now().Add(time.Hour)}
	if err := daemon.OpenSession(context.Background(), forgedSession); err != nil {
		t.Fatal(err)
	}
	attachEnvelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, SessionId: forgedSession.SessionID, GenerationId: forgedSession.GenerationID, CallerIdentity: forgedSession.Caller, SessionCredential: forgedCredential, RequestId: "forged-attach", DeadlineUnixMillis: time.Now().Add(time.Second).UnixMilli(), Payload: &subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: "agent-one", RequestedCapabilities: []string{"send"}}}}
	forgedAttach := request(t, path, attachEnvelope).GetAttachResponse()
	forgedAttempt := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, SessionId: forgedSession.SessionID, GenerationId: forgedSession.GenerationID, CallerIdentity: forgedSession.Caller, SessionCredential: forgedCredential, AgentHandle: forgedAttach.AgentHandle, AgentFence: forgedAttach.Fence, RequestId: "forged-message", DeadlineUnixMillis: time.Now().Add(time.Second).UnixMilli(), Payload: &subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_TELL, Target: "agent-one", BoundedPayload: []byte("denied"), DedupeId: "forged-denied", HopLimit: 8, ChainId: "forged-chain"}}}
	if message := request(t, path, forgedAttempt).GetActorMessageResponse(); message != nil && message.Accepted {
		t.Fatal("non-hosted principal forged a logical source")
	}
	subscribed := request(t, path, fencedBase(&subagentsv1.Envelope_SubscribeAgentRequest{SubscribeAgentRequest: &subagentsv1.SubscribeAgentRequest{AgentId: "agent-one"}}))
	if !subscribed.GetAgentOperationResponse().Completed {
		t.Fatalf("subscribe failed: %#v", subscribed)
	}
	unsubscribed := request(t, path, fencedBase(&subagentsv1.Envelope_UnsubscribeAgentRequest{UnsubscribeAgentRequest: &subagentsv1.UnsubscribeAgentRequest{AgentId: "agent-one"}}))
	if !unsubscribed.GetAgentOperationResponse().Completed {
		t.Fatalf("unsubscribe failed: %#v", unsubscribed)
	}

	tell := request(t, path, fencedBase(&subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_TELL, Target: "agent-one", BoundedPayload: []byte("no-provider-message"), DedupeId: "tell", HopLimit: 8, ChainId: "chain-tell", SourceMutationSequence: 1}}))
	if !tell.GetActorMessageResponse().Accepted {
		t.Fatalf("tell admission rejected: %#v", tell)
	}
	askResult := make(chan *subagentsv1.Envelope, 1)
	go func() {
		askResult <- request(t, path, fencedBase(&subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_ASK, Target: "agent-one", BoundedPayload: []byte("ask-message"), DedupeId: "ask", HopLimit: 8, ChainId: "chain-ask", SourceMutationSequence: 2}}))
	}()
	var deliveries []*subagentsv1.BridgeDelivery
	deadline := time.Now().Add(time.Second)
	for len(deliveries) < 2 && time.Now().Before(deadline) {
		poll := request(t, path, fencedBase(&subagentsv1.Envelope_BridgePollRequest{BridgePollRequest: &subagentsv1.BridgePollRequest{AgentId: "agent-one", MaxItems: 64}}))
		deliveries = poll.GetBridgePollResponse().Deliveries
		if len(deliveries) < 2 {
			time.Sleep(10 * time.Millisecond)
		}
	}
	if len(deliveries) != 2 {
		t.Fatalf("bridge did not retain both deliveries: %#v", deliveries)
	}
	for _, delivery := range deliveries {
		ackRequest := &subagentsv1.BridgeDeliveryAckRequest{AgentId: "agent-one", Sequence: delivery.Sequence, DedupeId: delivery.DedupeId, Delivered: true}
		if delivery.Kind == subagentsv1.BridgeDelivery_KIND_PROMPT {
			ackRequest.BoundedResult = []byte("model answer")
		}
		ack := request(t, path, fencedBase(&subagentsv1.Envelope_BridgeDeliveryAckRequest{BridgeDeliveryAckRequest: ackRequest}))
		if !ack.GetBridgeDeliveryAckResponse().Accepted {
			t.Fatalf("delivery ack rejected: %#v", ack)
		}
	}
	select {
	case response := <-askResult:
		if !response.GetActorMessageResponse().Completed {
			t.Fatalf("ask did not wait for ack: %#v", response)
		}
	case <-time.After(time.Second):
		t.Fatal("ask did not complete after delivery ack")
	}
	askReplay := request(t, path, fencedBase(&subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_ASK, Target: "agent-one", BoundedPayload: []byte("ask-message"), DedupeId: "ask", HopLimit: 8, ChainId: "chain-ask", SourceMutationSequence: 2}})).GetActorMessageResponse()
	if !askReplay.Accepted || !askReplay.Completed {
		t.Fatalf("completed ASK exact retry did not return immediately: %#v", askReplay)
	}
	duplicate := request(t, path, fencedBase(&subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_TELL, Target: "agent-one", BoundedPayload: []byte("changed"), DedupeId: "changed", HopLimit: 8, ChainId: "changed", SourceMutationSequence: 1}})).GetActorMessageResponse()
	if duplicate.Accepted || !strings.Contains(duplicate.Reason, "collision") {
		t.Fatalf("sequence collision did not fail closed: %#v", duplicate)
	}
	timed := fencedBase(&subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_ASK, Target: "agent-one", BoundedPayload: []byte("timeout"), DedupeId: "timeout", HopLimit: 8, ChainId: "timeout-chain", SourceMutationSequence: 3}})
	timed.DeadlineUnixMillis = time.Now().Add(50 * time.Millisecond).UnixMilli()
	if response := request(t, path, timed); response.GetProtocolError() == nil && (response.GetActorMessageResponse() == nil || response.GetActorMessageResponse().Completed || response.GetActorMessageResponse().Reason == "") {
		t.Fatalf("unacknowledged ask did not time out: %#v", response)
	}

	clientCredential := []byte(strings.Repeat("c", 32))
	client := application.OpenSession{SessionID: "client", GenerationID: "client-one", Caller: "human", Credential: clientCredential, Capabilities: []string{"observe"}, ExpiresAt: time.Now().Add(time.Hour)}
	if err := daemon.OpenSession(context.Background(), client); err != nil {
		t.Fatal(err)
	}
	if err := daemon.CloseSession(context.Background(), client.SessionID); err != nil {
		t.Fatal(err)
	}
	client.SessionID, client.GenerationID = "client-later", "client-two"
	if err := daemon.OpenSession(context.Background(), client); err != nil {
		t.Fatal(err)
	}
	clientRequest := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, SessionId: client.SessionID, GenerationId: client.GenerationID, CallerIdentity: client.Caller, SessionCredential: client.Credential, RequestId: "later-client", DeadlineUnixMillis: time.Now().Add(time.Second).UnixMilli(), Payload: &subagentsv1.Envelope_ResolveAgentRequest{ResolveAgentRequest: &subagentsv1.ResolveAgentRequest{AgentId: "agent-one"}}}
	if request(t, path, clientRequest).GetResolveAgentResponse().Agent.GetAgentId() != "agent-one" {
		t.Fatal("later client could not reuse global AgentActor")
	}
}
