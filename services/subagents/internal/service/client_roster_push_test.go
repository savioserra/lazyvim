package service

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/protocol"
)

func TestClientRosterStreamAuthenticatesSnapshotsAndPushesUpsertRemove(t *testing.T) {
	path := filepath.Join(rosterPrivateTempDir(t), "runtime", "control.sock")
	daemon, err := Start(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	credential := []byte(strings.Repeat("u", 32))
	if err := daemon.OpenSession(context.Background(), application.OpenSession{SessionID: "roster", GenerationID: "generation", Caller: "client:bar", Credential: credential, Capabilities: []string{"observe"}, ExpiresAt: time.Now().Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	connection, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	request := rosterAuthenticatedEnvelope("roster", "generation", "client:bar", credential, "roster-open", 1)
	request.Payload = &subagentsv1.Envelope_ClientAgentRosterRequest{ClientAgentRosterRequest: &subagentsv1.ClientAgentRosterRequest{}}
	if response := rosterRoundTrip(t, connection, request); !response.GetAgentOperationResponse().GetCompleted() {
		t.Fatalf("roster stream was not accepted: %#v", response)
	}
	reset := readRosterFrame(t, connection)
	if reset.Operation != subagentsv1.ClientAgentRosterFrame_OPERATION_SNAPSHOT_RESET || reset.Epoch == 0 || reset.Sequence == 0 {
		t.Fatalf("missing fenced snapshot reset: %#v", reset)
	}
	registration := application.RegisterAgent{AgentID: "bar-agent", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "observed-run"}, HostedPiRuntime: application.InactiveHostedPiRuntimeBinding(), AllowedCapability: []string{"observe"}, Retention: "explicit", Recovery: "metadata-only", DisplayName: "Bar Agent", Role: "Reviewer"}
	if err := daemon.RegisterAgent(context.Background(), registration); err != nil {
		t.Fatal(err)
	}
	upsert := readRosterOperation(t, connection, subagentsv1.ClientAgentRosterFrame_OPERATION_UPSERT)
	if upsert.AgentId != "bar-agent" || upsert.Agent.GetDisplayName() != "Bar Agent" || upsert.Sequence <= reset.Sequence {
		t.Fatalf("missing authoritative upsert: %#v after %#v", upsert, reset)
	}
	if err := daemon.unregisterHostedAgent(context.Background(), "bar-agent"); err != nil {
		t.Fatal(err)
	}
	remove := readRosterOperation(t, connection, subagentsv1.ClientAgentRosterFrame_OPERATION_REMOVE)
	if remove.AgentId != "bar-agent" || remove.Sequence <= upsert.Sequence {
		t.Fatalf("missing authoritative remove: %#v after %#v", remove, upsert)
	}
}

func readRosterOperation(t *testing.T, connection net.Conn, operation subagentsv1.ClientAgentRosterFrame_Operation) *subagentsv1.ClientAgentRosterFrame {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		frame := readRosterFrame(t, connection)
		if frame.Operation == operation {
			return frame
		}
	}
	t.Fatalf("timed out waiting for roster operation %v", operation)
	return nil
}

func rosterAuthenticatedEnvelope(session, generation, caller string, credential []byte, requestID string, sequence uint64) *subagentsv1.Envelope {
	return &subagentsv1.Envelope{ProtocolMajor: 1, SessionId: session, GenerationId: generation, CallerIdentity: caller, SessionCredential: credential, RequestId: requestID, Sequence: sequence, DeadlineUnixMillis: time.Now().Add(time.Minute).UnixMilli()}
}

func rosterRoundTrip(t *testing.T, connection net.Conn, envelope *subagentsv1.Envelope) *subagentsv1.Envelope {
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

func readRosterFrame(t *testing.T, connection net.Conn) *subagentsv1.ClientAgentRosterFrame {
	t.Helper()
	_ = connection.SetReadDeadline(time.Now().Add(2 * time.Second))
	envelope, err := protocol.ReadEnvelope(connection)
	if err != nil {
		t.Fatal(err)
	}
	frame := envelope.GetClientAgentRosterFrame()
	if frame == nil {
		t.Fatalf("expected roster frame, got %#v", envelope)
	}
	return frame
}

func rosterPrivateTempDir(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	return root
}
