package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/hostedpi"
	"github.com/savioserra/lazyvim/services/subagents/internal/protocol"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	var socket, credentialFile, operation, agentID, project, targetNode string
	var trust bool
	flag.StringVar(&socket, "socket", "", "client daemon Unix socket")
	flag.StringVar(&credentialFile, "credential", "", "client admin credential file")
	flag.StringVar(&operation, "operation", "status", "start, status, or stop")
	flag.StringVar(&agentID, "agent", "client", "logical hosted agent ID")
	flag.StringVar(&project, "project", "", "hosted Pi project directory")
	flag.StringVar(&targetNode, "target-node", "", "optional logical remoting node for hosted creation")
	flag.BoolVar(&trust, "trust-project", false, "allow Pi project-local resources")
	flag.Parse()
	if socket == "" || credentialFile == "" || agentID == "" {
		return errors.New("socket, credential, and agent are required")
	}
	var op subagentsv1.HostedAdminRequest_Operation
	switch operation {
	case "start":
		op = subagentsv1.HostedAdminRequest_OPERATION_START
		if project == "" {
			return errors.New("project is required for start")
		}
	case "status":
		op = subagentsv1.HostedAdminRequest_OPERATION_STATUS
	case "stop":
		op = subagentsv1.HostedAdminRequest_OPERATION_STOP
	default:
		return fmt.Errorf("unsupported operation %q", operation)
	}
	credential, err := hostedpi.ReadCredentialFile(credentialFile)
	if err != nil {
		return fmt.Errorf("read client admin credential: %w", err)
	}
	requestID, err := randomID()
	if err != nil {
		return err
	}
	request := &subagentsv1.Envelope{
		ProtocolMajor:      protocol.ProtocolMajor,
		ProtocolMinor:      protocol.ProtocolMinor,
		RequestId:          requestID,
		DeadlineUnixMillis: time.Now().Add(15 * time.Second).UnixMilli(),
		Sequence:           1,
		SessionCredential:  credential,
		Payload: &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{
			Operation: op, AgentId: agentID, ProjectDirectory: project, TrustProject: trust, TargetNode: targetNode,
		}},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	dialer := net.Dialer{}
	connection, err := dialer.DialContext(ctx, "unix", socket)
	if err != nil {
		return fmt.Errorf("connect client daemon: %w", err)
	}
	defer connection.Close()
	_ = connection.SetDeadline(time.Now().Add(20 * time.Second))
	if err := protocol.WriteEnvelope(connection, request); err != nil {
		return err
	}
	response, err := protocol.ReadEnvelope(connection)
	if err != nil {
		return err
	}
	if failure := response.GetProtocolError(); failure != nil {
		return errors.New(failure.Message)
	}
	admin := response.GetHostedAdminResponse()
	if admin == nil {
		return errors.New("daemon returned an unexpected response")
	}
	encoded, err := json.MarshalIndent(map[string]any{
		"accepted":      admin.Accepted,
		"agent_id":      admin.AgentId,
		"attach_target": admin.AttachTarget,
		"reason":        admin.Reason,
		"runtime_state": func() int32 {
			if admin.Runtime == nil {
				return 0
			}
			return int32(admin.Runtime.State)
		}(),
	}, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(encoded))
	if !admin.Accepted {
		return errors.New("client operation was rejected")
	}
	return nil
}

func randomID() (string, error) {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		return "", err
	}
	return hex.EncodeToString(value), nil
}
