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

func TestHostedBridgePushDeliversWithoutPoll(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"a", "b"} {
		if err := os.Mkdir(filepath.Join(root, name), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	socketPath := filepath.Join(root, "control.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	baseProcess := &clientProcess{binding: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, TmuxSessionID: "$push", TmuxWindowID: "@push", TmuxPane: "%push", PanePID: 44, ProcessStartToken: "push", TTY: "/dev/pts/44"}, done: make(chan error, 1)}
	daemon, err := startWithListener(context.Background(), listener, HostedAdminConfig{Enabled: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge", StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: filepath.Join(root, "admin.json"), DefaultProjectDirectory: root, TrustProject: true, RuntimeFactory: func(hostedpi.Config) application.HostedPiRuntime { return clientRuntime{process: baseProcess} }}, socketPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})

	dispatch := func(payload any, session application.OpenSession, handle string, fence uint64) *subagentsv1.Envelope {
		envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: time.Now().String(), DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli(), SessionId: session.SessionID, GenerationId: session.GenerationID, CallerIdentity: session.Caller, SessionCredential: session.Credential, AgentHandle: handle, AgentFence: fence}
		switch value := payload.(type) {
		case *subagentsv1.Envelope_HostedAdminRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_ClientSessionRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_AttachRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_ActorMessageRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_BridgeLifecycleRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_BridgeDeliveryAckRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_BridgePollRequest:
			envelope.Payload = value
		default:
			t.Fatalf("unsupported payload %T", payload)
		}
		return daemon.dispatch(envelope)
	}
	admin := application.OpenSession{Credential: daemon.adminCredential}
	for index, agent := range []string{"alpha", "beta"} {
		response := dispatch(&subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: agent, ProjectDirectory: filepath.Join(root, string(rune('a'+index))), TrustProject: true}}, admin, "", 0).GetHostedAdminResponse()
		if response == nil || !response.Accepted {
			t.Fatalf("start %s failed: %#v", agent, response)
		}
	}
	opened := dispatch(&subagentsv1.Envelope_ClientSessionRequest{ClientSessionRequest: &subagentsv1.ClientSessionRequest{Operation: subagentsv1.ClientSessionRequest_OPERATION_OPEN}}, admin, "", 0).GetClientSessionResponse()
	clientSession := application.OpenSession{SessionID: opened.SessionId, GenerationID: opened.GenerationId, Caller: opened.CallerIdentity, Credential: opened.SessionCredential}
	attached := dispatch(&subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: "alpha", RequestedCapabilities: []string{"observe", "send"}}}, clientSession, "", 0).GetAttachResponse()
	if attached == nil || attached.AgentHandle == "" {
		t.Fatalf("attach failed: %#v", attached)
	}

	records, err := daemon.durableStore.LoadAll(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var alpha, beta application.DurableHostedRecord
	for _, record := range records {
		if record.AgentID == "alpha" {
			alpha = record
		}
		if record.AgentID == "beta" {
			beta = record
		}
	}
	credential, err := hostedpi.ReadCredentialFile(alpha.Session.CredentialFile)
	if err != nil {
		t.Fatal(err)
	}
	host := application.OpenSession{SessionID: alpha.Session.SessionID, GenerationID: alpha.Session.GenerationID, Caller: alpha.Session.Caller, Credential: credential}
	connection, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: socketPath, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	sequence := uint64(0)
	request := func(payload any, handle string, fence uint64) *subagentsv1.Envelope {
		sequence++
		requestID := time.Now().String()
		envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: sequence, RequestId: requestID, DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli(), SessionId: host.SessionID, GenerationId: host.GenerationID, CallerIdentity: host.Caller, SessionCredential: host.Credential, AgentHandle: handle, AgentFence: fence}
		switch value := payload.(type) {
		case *subagentsv1.Envelope_BridgeConnectRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_BridgeLifecycleRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_BridgeDeliveryAckRequest:
			envelope.Payload = value
		default:
			t.Fatalf("unsupported socket payload %T", payload)
		}
		if err := protocol.WriteEnvelope(connection, envelope); err != nil {
			t.Fatal(err)
		}
		for {
			response, err := protocol.ReadEnvelope(connection)
			if err != nil {
				t.Fatal(err)
			}
			if response.RequestId == requestID {
				return response
			}
		}

	}
	connected := request(&subagentsv1.Envelope_BridgeConnectRequest{BridgeConnectRequest: &subagentsv1.BridgeConnectRequest{AgentId: "alpha", RuntimeId: alpha.LaunchSpec.RuntimeID, Incarnation: 1, PiSessionId: "push-alpha"}}, "", 0).GetBridgeConnectResponse()
	if connected == nil || !connected.Accepted {
		t.Fatalf("bridge connect failed: %#v", connected)
	}
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		daemon.pushMu.Lock()
		registered := len(daemon.pushSessions)
		daemon.pushMu.Unlock()
		if registered > 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	daemon.pushMu.Lock()
	registered := len(daemon.pushSessions)
	daemon.pushMu.Unlock()
	if registered == 0 {
		t.Fatal("bridge push session was not registered")
	}
	for _, event := range []subagentsv1.BridgeLifecycleRequest_Event{subagentsv1.BridgeLifecycleRequest_EVENT_SESSION_START, subagentsv1.BridgeLifecycleRequest_EVENT_READY} {
		response := request(&subagentsv1.Envelope_BridgeLifecycleRequest{BridgeLifecycleRequest: &subagentsv1.BridgeLifecycleRequest{AgentId: "alpha", RuntimeId: alpha.LaunchSpec.RuntimeID, Incarnation: 1, Event: event}}, connected.AgentHandle, connected.Fence).GetBridgeLifecycleResponse()
		if response == nil || !response.Accepted {
			t.Fatalf("lifecycle failed: %#v", response)
		}
	}

	if err := connection.CloseRead(); err != nil {
		t.Fatal(err)
	}
	betaCredential, err := hostedpi.ReadCredentialFile(beta.Session.CredentialFile)
	if err != nil {
		t.Fatal(err)
	}
	betaHost := application.OpenSession{SessionID: beta.Session.SessionID, GenerationID: beta.Session.GenerationID, Caller: beta.Session.Caller, Credential: betaCredential}
	betaAttach := dispatch(&subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: "alpha", RequestedCapabilities: []string{"send"}}}, betaHost, "", 0).GetAttachResponse()
	if betaAttach == nil || betaAttach.AgentHandle == "" {
		t.Fatalf("hosted source attach failed: %#v", betaAttach)
	}
	messageResponse := dispatch(&subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_TELL, Target: "alpha", BoundedPayload: []byte("pushed tell"), DedupeId: "push-dedupe", ChainId: "push-chain", HopLimit: 8, SourceMutationSequence: 1}}, betaHost, betaAttach.AgentHandle, betaAttach.Fence).GetActorMessageResponse()
	if messageResponse == nil || !messageResponse.Accepted {
		t.Fatalf("tell admission failed: %#v", messageResponse)
	}
	deadline = time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		daemon.pushMu.Lock()
		registered := len(daemon.pushSessions)
		daemon.pushMu.Unlock()
		if registered == 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	daemon.pushMu.Lock()
	registered = len(daemon.pushSessions)
	daemon.pushMu.Unlock()
	if registered != 0 {
		t.Fatal("writer-failed bridge push session remained registered")
	}
	replayConnection, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer replayConnection.Close()
	replaySequence := uint64(0)
	replayRequest := func(payload any, handle string, fence uint64) *subagentsv1.Envelope {
		replaySequence++
		requestID := time.Now().String()
		envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: replaySequence, RequestId: requestID, DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli(), SessionId: host.SessionID, GenerationId: host.GenerationID, CallerIdentity: host.Caller, SessionCredential: host.Credential, AgentHandle: handle, AgentFence: fence}
		switch value := payload.(type) {
		case *subagentsv1.Envelope_BridgeConnectRequest:
			envelope.Payload = value
		case *subagentsv1.Envelope_BridgeDeliveryAckRequest:
			envelope.Payload = value
		default:
			t.Fatalf("unsupported replay payload %T", payload)
		}
		if err := protocol.WriteEnvelope(replayConnection, envelope); err != nil {
			t.Fatal(err)
		}
		for {
			response, err := protocol.ReadEnvelope(replayConnection)
			if err != nil {
				t.Fatal(err)
			}
			if response.RequestId == requestID {
				return response
			}
		}
	}
	reconnected := replayRequest(&subagentsv1.Envelope_BridgeConnectRequest{BridgeConnectRequest: &subagentsv1.BridgeConnectRequest{AgentId: "alpha", RuntimeId: alpha.LaunchSpec.RuntimeID, Incarnation: 1, PiSessionId: "push-alpha", LastAckedSequence: 0}}, "", 0).GetBridgeConnectResponse()
	if reconnected == nil || !reconnected.Accepted {
		t.Fatalf("bridge reconnect failed: %#v", reconnected)
	}
	if err := replayConnection.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	var duplicate *subagentsv1.BridgeDelivery
	for duplicate == nil {
		frame, err := protocol.ReadEnvelope(replayConnection)
		if err != nil {
			t.Fatal(err)
		}
		push := frame.GetBridgePushFrame()
		if push != nil && len(push.Deliveries) > 0 {
			duplicate = push.Deliveries[0]
		}
	}
	if duplicate.DedupeId != "push-dedupe" || duplicate.Kind != subagentsv1.BridgeDelivery_KIND_NOTIFICATION || string(duplicate.BoundedPayload) != "pushed tell" {
		t.Fatalf("writer-failure reconnect did not replay same unacked delivery: %#v", duplicate)
	}
	requireAckIdentity(t, "notification replay", duplicate)
	ack := replayRequest(&subagentsv1.Envelope_BridgeDeliveryAckRequest{BridgeDeliveryAckRequest: identityBridgeAck("alpha", alpha.LaunchSpec.RuntimeID, "push-alpha", 1, duplicate, true, nil)}, reconnected.AgentHandle, reconnected.Fence).GetBridgeDeliveryAckResponse()
	if ack == nil || !ack.Accepted {
		t.Fatalf("push ack failed: %#v", ack)
	}
	pollAfterAck := dispatch(&subagentsv1.Envelope_BridgePollRequest{BridgePollRequest: &subagentsv1.BridgePollRequest{AgentId: "alpha", AfterSequence: 0, MaxItems: 64}}, host, reconnected.AgentHandle, reconnected.Fence).GetBridgePollResponse()
	if pollAfterAck == nil || len(pollAfterAck.Deliveries) != 0 {
		t.Fatalf("acked delivery replayed after acknowledgement: %#v", pollAfterAck)
	}
}
