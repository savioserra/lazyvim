package service

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/hostedpi"
	"github.com/savioserra/lazyvim/services/subagents/internal/protocol"
)

// requireAckIdentity fails unless a delivery decoded from a real serialized
// wire frame carries both halves of the acknowledgement identity the hosted
// bridge must echo: the opaque source scope token and the completion key.
func requireAckIdentity(t *testing.T, surface string, delivery *subagentsv1.BridgeDelivery) {
	t.Helper()
	if delivery.GetSourceScope() == "" || delivery.GetCompletionKey() == "" {
		t.Fatalf("%s delivery seq %d is missing acknowledgement identity (source_scope=%q completion_key=%q)", surface, delivery.GetSequence(), delivery.GetSourceScope(), delivery.GetCompletionKey())
	}
}

// bridgeIdentityHarness drives a real daemon over its unix control socket with
// two hosted agents, a live bridge session for the target agent, and a hosted
// source attach for the asking agent.
type bridgeIdentityHarness struct {
	t          *testing.T
	root       string
	socketPath string
	daemon     *Service
	admin      application.OpenSession
	alpha      application.DurableHostedRecord
	beta       application.DurableHostedRecord
	alphaHost  application.OpenSession
	betaHost   application.OpenSession
	betaAtt    *subagentsv1.AttachResponse
}

func startBridgeIdentityHarness(t *testing.T, root string, socketPath string) *bridgeIdentityHarness {
	t.Helper()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"a", "b"} {
		if err := os.Mkdir(filepath.Join(root, name), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	baseProcess := &clientProcess{binding: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, TmuxSessionID: "$ident", TmuxWindowID: "@ident", TmuxPane: "%ident", PanePID: 46, ProcessStartToken: "ident", TTY: "/dev/pts/46"}, done: make(chan error, 1)}
	daemon, err := startWithListener(context.Background(), listener, HostedAdminConfig{Enabled: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge", StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: filepath.Join(root, "admin.json"), DefaultProjectDirectory: root, TrustProject: true, RuntimeFactory: func(hostedpi.Config) application.HostedPiRuntime { return clientRuntime{process: baseProcess} }}, socketPath)
	if err != nil {
		t.Fatal(err)
	}
	harness := &bridgeIdentityHarness{t: t, root: root, socketPath: socketPath, daemon: daemon}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	harness.admin = application.OpenSession{Credential: daemon.adminCredential}
	for index, agent := range []string{"alpha", "beta"} {
		started := harness.dispatch(&subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: agent, ProjectDirectory: filepath.Join(root, string(rune('a'+index))), TrustProject: true}}, harness.admin, "", 0, "start-"+agent).GetHostedAdminResponse()
		if started == nil || !started.Accepted {
			harness.t.Fatalf("start %s failed: %#v", agent, started)
		}
	}
	if err := harness.reloadRecords(); err != nil {
		t.Fatal(err)
	}
	credential, err := hostedpi.ReadCredentialFile(harness.alpha.Session.CredentialFile)
	if err != nil {
		t.Fatal(err)
	}
	harness.alphaHost = application.OpenSession{SessionID: harness.alpha.Session.SessionID, GenerationID: harness.alpha.Session.GenerationID, Caller: harness.alpha.Session.Caller, Credential: credential}
	betaCredential, err := hostedpi.ReadCredentialFile(harness.beta.Session.CredentialFile)
	if err != nil {
		t.Fatal(err)
	}
	harness.betaHost = application.OpenSession{SessionID: harness.beta.Session.SessionID, GenerationID: harness.beta.Session.GenerationID, Caller: harness.beta.Session.Caller, Credential: betaCredential}
	return harness
}

func (h *bridgeIdentityHarness) reloadRecords() error {
	records, err := h.daemon.durableStore.LoadAll(context.Background())
	if err != nil {
		return err
	}
	for _, record := range records {
		if record.AgentID == "alpha" {
			h.alpha = record
		}
		if record.AgentID == "beta" {
			h.beta = record
		}
	}
	return nil
}

func (h *bridgeIdentityHarness) dispatch(payload any, session application.OpenSession, handle string, fence uint64, id string) *subagentsv1.Envelope {
	h.t.Helper()
	envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: uint64(time.Now().UnixNano()), RequestId: id, DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli(), SessionId: session.SessionID, GenerationId: session.GenerationID, CallerIdentity: session.Caller, SessionCredential: session.Credential, AgentHandle: handle, AgentFence: fence}
	switch value := payload.(type) {
	case *subagentsv1.Envelope_HostedAdminRequest:
		envelope.Payload = value
	case *subagentsv1.Envelope_AttachRequest:
		envelope.Payload = value
	case *subagentsv1.Envelope_ActorMessageRequest:
		envelope.Payload = value
	default:
		h.t.Fatalf("unsupported dispatch payload %T", payload)
	}
	return h.daemon.dispatch(envelope)
}

// hostedSourceAsk attaches the hosted beta agent to alpha and issues an Ask
// whose delivery must reach alpha's bridge with full acknowledgement identity.
func (h *bridgeIdentityHarness) hostedSourceAsk(dedupe, chain string, sequence uint64) *subagentsv1.ActorMessageResponse {
	h.t.Helper()
	if h.betaAtt == nil {
		h.betaAtt = h.dispatch(&subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: "alpha", RequestedCapabilities: []string{"send", "ask"}}}, h.betaHost, "", 0, "attach-beta").GetAttachResponse()
		if h.betaAtt == nil || h.betaAtt.AgentHandle == "" {
			h.t.Fatalf("hosted source attach failed: %#v", h.betaAtt)
		}
	}
	return h.dispatch(&subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_ASK, Target: "alpha", BoundedPayload: []byte("wake up"), DedupeId: dedupe, ChainId: chain, HopLimit: 8, SourceMutationSequence: sequence}}, h.betaHost, h.betaAtt.AgentHandle, h.betaAtt.Fence, "ask-"+dedupe).GetActorMessageResponse()
}

// framedBridge is a live bridge connection for alpha over the unix socket.
type framedBridge struct {
	t       *testing.T
	conn    net.Conn
	sequ    uint64
	runtime string
	pi      string
	handle  string
	fence   uint64
}

func (h *bridgeIdentityHarness) bridgeConnect(piSession string, lastAcked uint64) *framedBridge {
	h.t.Helper()
	connection, err := net.Dial("unix", h.socketPath)
	if err != nil {
		h.t.Fatal(err)
	}
	bridge := &framedBridge{t: h.t, conn: connection, runtime: h.alpha.LaunchSpec.RuntimeID, pi: piSession}
	connected := bridge.request(&subagentsv1.Envelope_BridgeConnectRequest{BridgeConnectRequest: &subagentsv1.BridgeConnectRequest{AgentId: "alpha", RuntimeId: h.alpha.LaunchSpec.RuntimeID, Incarnation: 1, PiSessionId: piSession, LastAckedSequence: lastAcked}}, h.alphaHost, "", 0, "bridge-connect").GetBridgeConnectResponse()
	if connected == nil || !connected.Accepted {
		connection.Close()
		h.t.Fatalf("bridge connect failed: %#v", connected)
	}
	bridge.handle, bridge.fence = connected.AgentHandle, connected.Fence
	return bridge
}

func (b *framedBridge) request(payload any, session application.OpenSession, handle string, fence uint64, id string) *subagentsv1.Envelope {
	b.t.Helper()
	b.sequ++
	envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: b.sequ, RequestId: id, DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli(), SessionId: session.SessionID, GenerationId: session.GenerationID, CallerIdentity: session.Caller, SessionCredential: session.Credential, AgentHandle: handle, AgentFence: fence}
	switch value := payload.(type) {
	case *subagentsv1.Envelope_BridgeConnectRequest:
		envelope.Payload = value
	case *subagentsv1.Envelope_BridgeLifecycleRequest:
		envelope.Payload = value
	case *subagentsv1.Envelope_BridgeDeliveryAckRequest:
		envelope.Payload = value
	case *subagentsv1.Envelope_BridgePollRequest:
		envelope.Payload = value
	default:
		b.t.Fatalf("unsupported bridge payload %T", payload)
	}
	if err := protocol.WriteEnvelope(b.conn, envelope); err != nil {
		b.t.Fatal(err)
	}
	for {
		response, err := protocol.ReadEnvelope(b.conn)
		if err != nil {
			b.t.Fatal(err)
		}
		if response.RequestId == id {
			return response
		}
	}
}

func (b *framedBridge) lifecycle(session application.OpenSession, event subagentsv1.BridgeLifecycleRequest_Event) {
	b.t.Helper()
	response := b.request(&subagentsv1.Envelope_BridgeLifecycleRequest{BridgeLifecycleRequest: &subagentsv1.BridgeLifecycleRequest{AgentId: "alpha", RuntimeId: b.runtime, Incarnation: 1, Event: event}}, session, b.handle, b.fence, event.String()).GetBridgeLifecycleResponse()
	if response == nil || !response.Accepted {
		b.t.Fatalf("lifecycle %s failed: %#v", event, response)
	}
}

// nextPushedDelivery blocks until a pushed frame carrying deliveries arrives
// and returns the first delivery decoded from the real serialized wire frame.
func (b *framedBridge) nextPushedDelivery(timeout time.Duration) *subagentsv1.BridgeDelivery {
	b.t.Helper()
	if err := b.conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		b.t.Fatal(err)
	}
	defer func() {
		if err := b.conn.SetReadDeadline(time.Time{}); err != nil {
			b.t.Fatal(err)
		}
	}()
	for {
		frame, err := protocol.ReadEnvelope(b.conn)
		if err != nil {
			b.t.Fatal(err)
		}
		if push := frame.GetBridgePushFrame(); push != nil && len(push.Deliveries) > 0 {
			return push.Deliveries[0]
		}
	}
}

func (b *framedBridge) poll(session application.OpenSession, after uint64) *subagentsv1.BridgePollResponse {
	b.t.Helper()
	return b.request(&subagentsv1.Envelope_BridgePollRequest{BridgePollRequest: &subagentsv1.BridgePollRequest{AgentId: "alpha", AfterSequence: after, MaxItems: 64}}, session, b.handle, b.fence, "poll").GetBridgePollResponse()
}

func (b *framedBridge) acknowledge(session application.OpenSession, delivery *subagentsv1.BridgeDelivery, result []byte) *subagentsv1.BridgeDeliveryAckResponse {
	b.t.Helper()
	request := identityBridgeAck("alpha", b.runtime, b.pi, 1, delivery, true, result)
	return b.request(&subagentsv1.Envelope_BridgeDeliveryAckRequest{BridgeDeliveryAckRequest: request}, session, b.handle, b.fence, "ack").GetBridgeDeliveryAckResponse()
}

// TestPushedAndPolledAskDeliveriesCarryAcknowledgementIdentity captures the
// actual envelopes a hosted bridge receives — a serialized BridgePushFrame and
// a serialized BridgePollResponse — and fails unless every prompt-kind
// delivery carries a non-empty source scope token and completion key, then
// proves the acknowledged chain advances the cursor.
func TestPushedAndPolledAskDeliveriesCarryAcknowledgementIdentity(t *testing.T) {
	root := t.TempDir()
	harness := startBridgeIdentityHarness(t, root, filepath.Join(root, "control.sock"))
	bridge := harness.bridgeConnect("identity-pi", 0)
	defer bridge.conn.Close()
	bridge.lifecycle(harness.alphaHost, subagentsv1.BridgeLifecycleRequest_EVENT_SESSION_START)
	bridge.lifecycle(harness.alphaHost, subagentsv1.BridgeLifecycleRequest_EVENT_READY)

	admission := harness.hostedSourceAsk("identity-dedupe", "identity-chain", 1)
	if admission == nil || !admission.Accepted || admission.Completed {
		t.Fatalf("hosted source ask admission failed: %#v", admission)
	}
	pushed := bridge.nextPushedDelivery(3 * time.Second)
	if pushed.GetKind() != subagentsv1.BridgeDelivery_KIND_PROMPT {
		t.Fatalf("expected prompt-kind delivery, got %#v", pushed.GetKind())
	}
	requireAckIdentity(t, "pushed", pushed)

	// The poll surface must expose the same identity, not a stripped copy.
	polled := bridge.poll(harness.alphaHost, 0)
	if polled == nil {
		t.Fatal("poll response missing")
	}
	if len(polled.Deliveries) == 0 {
		t.Fatal("poll response lost the queued delivery")
	}
	for _, delivery := range polled.Deliveries {
		requireAckIdentity(t, "polled", delivery)
	}

	ack := bridge.acknowledge(harness.alphaHost, pushed, []byte("WAKE-OK"))
	if ack == nil || !ack.Accepted {
		t.Fatalf("identity acknowledgement rejected: %#v", ack)
	}
	if ack.GetCursor() != pushed.GetSequence() {
		t.Fatalf("acknowledgement did not advance the cursor: delivery seq %d cursor %d", pushed.GetSequence(), ack.GetCursor())
	}
	if after := bridge.poll(harness.alphaHost, 0); after != nil && len(after.Deliveries) != 0 {
		t.Fatalf("acknowledged delivery replayed after cursor advance: %#v", after.Deliveries)
	}
}

// TestReconnectReplayFrameCarriesAcknowledgementIdentityAndCommitsCursor
// models the deployed incident sequencing exactly: a prompt delivery is queued
// with full acknowledgement identity BEFORE the bridge connection bounces, and
// afterwards it is consumed exclusively through reconnect replay from the
// acknowledgement cursor. The replayed frame must still carry the source scope
// token and completion key on every serializing surface, the acknowledgement
// built from the replayed frame must commit, and the cursor must advance so the
// delivery is never served again.
func TestReconnectReplayFrameCarriesAcknowledgementIdentityAndCommitsCursor(t *testing.T) {
	root := t.TempDir()
	harness := startBridgeIdentityHarness(t, root, filepath.Join(root, "control.sock"))
	bridge := harness.bridgeConnect("replay-pi", 0)
	bridge.lifecycle(harness.alphaHost, subagentsv1.BridgeLifecycleRequest_EVENT_SESSION_START)
	bridge.lifecycle(harness.alphaHost, subagentsv1.BridgeLifecycleRequest_EVENT_READY)

	// Queue the delivery before the bounce with a deadline that outlives the
	// reconnect, mirroring a durable prompt that survives a bridge restart.
	att := harness.dispatch(&subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: "alpha", RequestedCapabilities: []string{"send", "ask"}}}, harness.betaHost, "", 0, "attach-replay-source").GetAttachResponse()
	if att == nil || att.AgentHandle == "" {
		t.Fatalf("hosted source attach failed: %#v", att)
	}
	ask := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: "ask-replay", DeadlineUnixMillis: time.Now().Add(60 * time.Second).UnixMilli(), SessionId: harness.betaHost.SessionID, GenerationId: harness.betaHost.GenerationID, CallerIdentity: harness.betaHost.Caller, SessionCredential: harness.betaHost.Credential, AgentHandle: att.AgentHandle, AgentFence: att.Fence, Payload: &subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_ASK, Target: "alpha", BoundedPayload: []byte("wake up"), DedupeId: "replay-dedupe", ChainId: "replay-chain", HopLimit: 8, SourceMutationSequence: 1}}}
	admission := harness.daemon.dispatch(ask).GetActorMessageResponse()
	if admission == nil || !admission.Accepted || admission.Completed {
		t.Fatalf("hosted source ask admission failed: %#v", admission)
	}

	// Bounce: drop the bridge connection without acknowledging anything, then
	// reconnect from the still-zero acknowledgement cursor.
	handle, fence := bridge.handle, bridge.fence
	if err := bridge.conn.Close(); err != nil {
		t.Fatal(err)
	}
	reconnected := harness.bridgeConnect("replay-pi", 0)
	defer reconnected.conn.Close()
	if reconnected.handle != handle || reconnected.fence != fence {
		t.Fatalf("idempotent reconnect rotated bridge fence: first=%s/%d second=%s/%d", handle, fence, reconnected.handle, reconnected.fence)
	}

	// The reconnect replay must deliver the queued prompt with its full
	// acknowledgement identity, exactly like the initial push surface.
	replayed := reconnected.nextPushedDelivery(3 * time.Second)
	if replayed.GetKind() != subagentsv1.BridgeDelivery_KIND_PROMPT {
		t.Fatalf("expected prompt-kind replayed delivery, got %#v", replayed.GetKind())
	}
	requireAckIdentity(t, "reconnect replay", replayed)

	// The poll surface after reconnect must expose the same identity, not a
	// stripped copy: poll from the same zero cursor and compare.
	polled := reconnected.poll(harness.alphaHost, 0)
	if polled == nil {
		t.Fatal("poll response missing after reconnect")
	}
	found := false
	for _, delivery := range polled.Deliveries {
		requireAckIdentity(t, "polled after reconnect", delivery)
		if delivery.GetSequence() == replayed.GetSequence() && delivery.GetDedupeId() == replayed.GetDedupeId() {
			found = true
		}
	}
	if !found {
		t.Fatalf("poll after reconnect lost the replayed delivery seq %d: %#v", replayed.GetSequence(), polled.Deliveries)
	}

	// The acknowledgement built from the replayed frame must commit and
	// advance the cursor so the delivery is never served again.
	ack := reconnected.acknowledge(harness.alphaHost, replayed, []byte("WAKE2-OK"))
	if ack == nil || !ack.Accepted {
		t.Fatalf("replayed acknowledgement rejected: %#v", ack)
	}
	if ack.GetCursor() != replayed.GetSequence() {
		t.Fatalf("replayed acknowledgement did not advance the cursor: delivery seq %d cursor %d", replayed.GetSequence(), ack.GetCursor())
	}
	if after := reconnected.poll(harness.alphaHost, 0); after != nil && len(after.Deliveries) != 0 {
		t.Fatalf("acknowledged replayed delivery served again after cursor advance: %#v", after.Deliveries)
	}
}
