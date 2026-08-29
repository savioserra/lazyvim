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

func TestActorAskAdmissionThenPushedReplyAndReconnectReplayOnce(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(root, "agent"), 0o700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", filepath.Join(root, "control.sock"))
	if err != nil {
		t.Fatal(err)
	}
	process := &clientProcess{binding: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, TmuxSessionID: "$reply", TmuxWindowID: "@reply", TmuxPane: "%reply", PanePID: 45, ProcessStartToken: "reply", TTY: "/dev/pts/45"}, done: make(chan error, 1)}
	daemon, err := startWithListener(context.Background(), listener, HostedAdminConfig{Enabled: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge", StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: filepath.Join(root, "admin.json"), DefaultProjectDirectory: root, TrustProject: true, RuntimeFactory: func(hostedpi.Config) application.HostedPiRuntime { return clientRuntime{process: process} }}, filepath.Join(root, "control.sock"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	admin := application.OpenSession{Credential: daemon.adminCredential}
	dispatch := func(session application.OpenSession, payload any, handle string, fence uint64) *subagentsv1.Envelope {
		envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: uint64(time.Now().UnixNano()), RequestId: time.Now().String(), DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli(), SessionId: session.SessionID, GenerationId: session.GenerationID, CallerIdentity: session.Caller, SessionCredential: session.Credential, AgentHandle: handle, AgentFence: fence}
		switch p := payload.(type) {
		case *subagentsv1.Envelope_HostedAdminRequest:
			envelope.Payload = p
		case *subagentsv1.Envelope_ClientSessionRequest:
			envelope.Payload = p
		case *subagentsv1.Envelope_AttachRequest:
			envelope.Payload = p
		default:
			t.Fatalf("bad payload %T", payload)
		}
		return daemon.dispatch(envelope)
	}
	started := dispatch(admin, &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: "alpha", ProjectDirectory: filepath.Join(root, "agent"), TrustProject: true}}, "", 0).GetHostedAdminResponse()
	if started == nil || !started.Accepted {
		t.Fatalf("start: %#v", started)
	}
	opened := dispatch(admin, &subagentsv1.Envelope_ClientSessionRequest{ClientSessionRequest: &subagentsv1.ClientSessionRequest{Operation: subagentsv1.ClientSessionRequest_OPERATION_OPEN}}, "", 0).GetClientSessionResponse()
	client := application.OpenSession{SessionID: opened.SessionId, GenerationID: opened.GenerationId, Caller: opened.CallerIdentity, Credential: opened.SessionCredential}
	attached := dispatch(client, &subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: "alpha", RequestedCapabilities: []string{"observe", "ask"}}}, "", 0).GetAttachResponse()
	if attached == nil || attached.AgentHandle == "" {
		t.Fatalf("attach: %#v", attached)
	}
	records, _ := daemon.durableStore.LoadAll(context.Background())
	cred, err := hostedpi.ReadCredentialFile(records[0].Session.CredentialFile)
	if err != nil {
		t.Fatal(err)
	}
	host := application.OpenSession{SessionID: records[0].Session.SessionID, GenerationID: records[0].Session.GenerationID, Caller: records[0].Session.Caller, Credential: cred}
	hostConn, err := net.Dial("unix", filepath.Join(root, "control.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer hostConn.Close()
	clientConn, err := net.Dial("unix", filepath.Join(root, "control.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer clientConn.Close()
	seq := uint64(0)
	request := func(conn net.Conn, session application.OpenSession, payload any, handle string, fence uint64, id string) *subagentsv1.Envelope {
		seq++
		env := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: seq, RequestId: id, DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli(), SessionId: session.SessionID, GenerationId: session.GenerationID, CallerIdentity: session.Caller, SessionCredential: session.Credential, AgentHandle: handle, AgentFence: fence}
		switch p := payload.(type) {
		case *subagentsv1.Envelope_BridgeConnectRequest:
			env.Payload = p
		case *subagentsv1.Envelope_BridgeLifecycleRequest:
			env.Payload = p
		case *subagentsv1.Envelope_BridgeDeliveryAckRequest:
			env.Payload = p
		case *subagentsv1.Envelope_ActorMessageRequest:
			env.Payload = p
		case *subagentsv1.Envelope_ListAgentsRequest:
			env.Payload = p
		}
		if err := protocol.WriteEnvelope(conn, env); err != nil {
			t.Fatal(err)
		}
		for {
			r, err := protocol.ReadEnvelope(conn)
			if err != nil {
				t.Fatal(err)
			}
			if r.RequestId == id {
				return r
			}
		}
	}
	connected := request(hostConn, host, &subagentsv1.Envelope_BridgeConnectRequest{BridgeConnectRequest: &subagentsv1.BridgeConnectRequest{AgentId: "alpha", RuntimeId: records[0].LaunchSpec.RuntimeID, Incarnation: 1, PiSessionId: "pi"}}, "", 0, "connect").GetBridgeConnectResponse()
	for _, ev := range []subagentsv1.BridgeLifecycleRequest_Event{subagentsv1.BridgeLifecycleRequest_EVENT_SESSION_START, subagentsv1.BridgeLifecycleRequest_EVENT_READY} {
		if !request(hostConn, host, &subagentsv1.Envelope_BridgeLifecycleRequest{BridgeLifecycleRequest: &subagentsv1.BridgeLifecycleRequest{AgentId: "alpha", RuntimeId: records[0].LaunchSpec.RuntimeID, Incarnation: 1, Event: ev}}, connected.AgentHandle, connected.Fence, ev.String()).GetBridgeLifecycleResponse().Accepted {
			t.Fatal("lifecycle")
		}
	}
	_ = request(clientConn, client, &subagentsv1.Envelope_ListAgentsRequest{ListAgentsRequest: &subagentsv1.ListAgentsRequest{}}, "", 0, "prime")
	admit := request(clientConn, client, &subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_ASK, Target: "alpha", BoundedPayload: []byte("question"), DedupeId: "dedupe", ChainId: "chain", HopLimit: 8, SourceMutationSequence: 1}}, attached.AgentHandle, attached.Fence, "ask").GetActorMessageResponse()
	if admit == nil || !admit.Accepted || admit.Completed {
		t.Fatalf("admission: %#v", admit)
	}
	var delivery *subagentsv1.BridgeDelivery
	for delivery == nil {
		frame, err := protocol.ReadEnvelope(hostConn)
		if err != nil {
			t.Fatal(err)
		}
		if push := frame.GetBridgePushFrame(); push != nil && len(push.Deliveries) > 0 {
			delivery = push.Deliveries[0]
		}
	}
	ack := request(hostConn, host, &subagentsv1.Envelope_BridgeDeliveryAckRequest{BridgeDeliveryAckRequest: &subagentsv1.BridgeDeliveryAckRequest{AgentId: "alpha", Sequence: delivery.Sequence, DedupeId: delivery.DedupeId, Delivered: true, BoundedResult: []byte("answer")}}, connected.AgentHandle, connected.Fence, "ack").GetBridgeDeliveryAckResponse()
	if ack == nil || !ack.Accepted {
		t.Fatalf("ack: %#v", ack)
	}
	if err := clientConn.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	pushed, err := protocol.ReadEnvelope(clientConn)
	if err != nil {
		t.Fatal(err)
	}
	reply := pushed.GetActorMessageReplyFrame()
	if reply == nil || reply.OriginalRequestId != "ask" || string(reply.BoundedResult) != "answer" || !reply.Completed {
		t.Fatalf("reply: %#v", pushed)
	}
	_ = clientConn.Close()
	again, err := net.Dial("unix", filepath.Join(root, "control.sock"))
	if err != nil {
		t.Fatal(err)
	}
	defer again.Close()
	_ = request(again, client, &subagentsv1.Envelope_ListAgentsRequest{ListAgentsRequest: &subagentsv1.ListAgentsRequest{}}, "", 0, "prime2")
	if err := again.SetReadDeadline(time.Now().Add(200 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	if frame, err := protocol.ReadEnvelope(again); err == nil && frame.GetActorMessageReplyFrame() != nil {
		t.Fatal("reply replayed more than once")
	}
}
