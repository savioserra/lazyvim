package service_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/hostedpi"
	"github.com/savioserra/lazyvim/services/subagents/internal/protocol"
	"github.com/savioserra/lazyvim/services/subagents/internal/service"
)

type failingHostedRuntime struct{ err error }

func (r failingHostedRuntime) Start(context.Context, application.HostedPiLaunchSpec) (application.HostedPiOwnedProcess, error) {
	return nil, r.err
}

type launchAwareRuntime struct {
	started  chan struct{}
	release  chan struct{}
	canceled chan struct{}
}

func (r *launchAwareRuntime) Start(ctx context.Context, spec application.HostedPiLaunchSpec) (application.HostedPiOwnedProcess, error) {
	if r.started != nil {
		close(r.started)
	}
	if r.release != nil {
		select {
		case <-r.release:
		case <-ctx.Done():
			if r.canceled != nil {
				close(r.canceled)
			}
			return nil, ctx.Err()
		}
	}
	binding := application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, RuntimeID: spec.RuntimeID, Incarnation: spec.Incarnation, TmuxSession: spec.TmuxSession, TmuxSessionID: "$42", TmuxWindow: spec.TmuxWindow, TmuxWindowID: "@42", TmuxPane: "%42", PanePID: 42, ProcessStartToken: "start", TTY: "/dev/pts/42"}
	return &deterministicProcess{binding: binding, exit: make(chan error, 1)}, nil
}

func TestAuthenticatedHostedAdminBootstrapsStartsStatusesAndStops(t *testing.T) {
	root := privateTempDir(t)
	socket := filepath.Join(root, "runtime", "control.sock")
	adminFile := filepath.Join(root, "admin", "credential.json")
	binding := application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, RuntimeID: "factory-overwritten", Incarnation: 1, TmuxSession: "ws-pi-admin", TmuxSessionID: "$9", TmuxWindow: "pi", TmuxWindowID: "@9", TmuxPane: "%9", PanePID: 99, ProcessStartToken: "start", TTY: "/dev/pts/9"}
	process := &deterministicProcess{binding: binding, exit: make(chan error, 1)}
	daemon, err := service.StartConfigured(context.Background(), socket, service.HostedAdminConfig{Enabled: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge.ts", StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: adminFile, DefaultProjectDirectory: root, RuntimeFactory: func(hostedpi.Config) application.HostedPiRuntime { return deterministicRuntime{process: process} }})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	contents, err := os.ReadFile(adminFile)
	if err != nil {
		t.Fatal(err)
	}
	var stored struct {
		Credential string `json:"credential_b64"`
	}
	if err := json.Unmarshal(contents, &stored); err != nil {
		t.Fatal(err)
	}
	adminCredential, err := base64.StdEncoding.DecodeString(stored.Credential)
	if err != nil || len(adminCredential) != 32 {
		t.Fatal("invalid admin bootstrap credential")
	}
	admin := func(credential []byte, operation subagentsv1.HostedAdminRequest_Operation) *subagentsv1.Envelope {
		return request(t, socket, &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: time.Now().String(), DeadlineUnixMillis: time.Now().Add(time.Second).UnixMilli(), SessionCredential: credential, Payload: &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: operation, AgentId: "admin-agent", ProjectDirectory: root}}})
	}
	if unauthorized := admin([]byte(strings.Repeat("x", 32)), subagentsv1.HostedAdminRequest_OPERATION_START); unauthorized.GetProtocolError() == nil {
		t.Fatal("unauthenticated hosted activation was accepted")
	}
	started := admin(adminCredential, subagentsv1.HostedAdminRequest_OPERATION_START).GetHostedAdminResponse()
	if !started.GetAccepted() || started.GetRuntime() == nil || started.GetAttachTarget() == "" {
		t.Fatalf("authenticated hosted start failed: %#v", started)
	}
	if strings.Contains(started.String(), base64.StdEncoding.EncodeToString(adminCredential)) {
		t.Fatal("admin response exposed credential")
	}
	files, err := filepath.Glob(filepath.Join(root, "credentials", "*.json"))
	if err != nil || len(files) != 1 {
		t.Fatalf("session credential was not bootstrapped: %v %v", files, err)
	}
	if info, err := os.Stat(files[0]); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("session credential is not 0600: %v", err)
	}
	status := admin(adminCredential, subagentsv1.HostedAdminRequest_OPERATION_STATUS).GetHostedAdminResponse()
	if !status.GetAccepted() {
		t.Fatalf("hosted status failed: %#v", status)
	}
	stopped := admin(adminCredential, subagentsv1.HostedAdminRequest_OPERATION_STOP).GetHostedAdminResponse()
	if !stopped.GetAccepted() || stopped.GetRuntime().GetState() != subagentsv1.HostedPiRuntimeBinding_STATE_STOPPED {
		t.Fatalf("exact hosted stop failed: %#v", stopped)
	}
	if _, err := os.Stat(files[0]); !os.IsNotExist(err) {
		t.Fatal("hosted session credential survived exact stop")
	}
	retried := admin(adminCredential, subagentsv1.HostedAdminRequest_OPERATION_START).GetHostedAdminResponse()
	if !retried.GetAccepted() {
		t.Fatalf("START was not retryable after exact STOP: %#v", retried)
	}
	if duplicate := admin(adminCredential, subagentsv1.HostedAdminRequest_OPERATION_START).GetHostedAdminResponse(); duplicate.GetAccepted() {
		t.Fatal("duplicate active START was accepted")
	}
	if !admin(adminCredential, subagentsv1.HostedAdminRequest_OPERATION_STOP).GetHostedAdminResponse().GetAccepted() {
		t.Fatal("retried hosted runtime did not stop")
	}
	if duplicateStop := admin(adminCredential, subagentsv1.HostedAdminRequest_OPERATION_STOP).GetHostedAdminResponse(); !duplicateStop.GetAccepted() || duplicateStop.GetRuntime().GetState() != subagentsv1.HostedPiRuntimeBinding_STATE_STOPPED {
		t.Fatalf("duplicate STOP was not idempotent: %#v", duplicateStop)
	}
}

func TestHostedAdminDefinitiveFailedStartUnregistersAndRetries(t *testing.T) {
	root := privateTempDir(t)
	socket := filepath.Join(root, "runtime", "control.sock")
	adminFile := filepath.Join(root, "admin", "credential.json")
	attempt := 0
	config := service.HostedAdminConfig{Enabled: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge.ts", StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: adminFile, DefaultProjectDirectory: root, RuntimeFactory: func(hostedpi.Config) application.HostedPiRuntime {
		attempt++
		if attempt == 1 {
			return failingHostedRuntime{err: errors.New("transient start failure")}
		}
		return &launchAwareRuntime{}
	}}
	daemon, err := service.StartConfigured(context.Background(), socket, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	contents, _ := os.ReadFile(adminFile)
	var stored struct {
		Credential string `json:"credential_b64"`
	}
	_ = json.Unmarshal(contents, &stored)
	credential, _ := base64.StdEncoding.DecodeString(stored.Credential)
	admin := func(operation subagentsv1.HostedAdminRequest_Operation) *subagentsv1.HostedAdminResponse {
		return request(t, socket, &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: time.Now().String(), DeadlineUnixMillis: time.Now().Add(3 * time.Second).UnixMilli(), SessionCredential: credential, Payload: &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: operation, AgentId: "retry-agent", ProjectDirectory: root}}}).GetHostedAdminResponse()
	}
	if first := admin(subagentsv1.HostedAdminRequest_OPERATION_START); first.GetAccepted() {
		t.Fatal("transient failed START was accepted")
	}
	if files, _ := filepath.Glob(filepath.Join(root, "credentials", "*.json")); len(files) != 0 {
		t.Fatalf("failed START leaked credentials: %v", files)
	}
	if second := admin(subagentsv1.HostedAdminRequest_OPERATION_START); !second.GetAccepted() {
		t.Fatalf("definitive failed START was not retryable: %#v", second)
	}
	if stopped := admin(subagentsv1.HostedAdminRequest_OPERATION_STOP); !stopped.GetAccepted() {
		t.Fatalf("retried runtime did not stop: %#v", stopped)
	}
}

func TestHostedAdminStartDeadlineDoesNotKillPublishedAgent(t *testing.T) {
	root := privateTempDir(t)
	socket := filepath.Join(root, "runtime", "control.sock")
	adminFile := filepath.Join(root, "admin", "credential.json")
	runtime := &launchAwareRuntime{started: make(chan struct{}), release: make(chan struct{})}
	config := service.HostedAdminConfig{Enabled: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge.ts", StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: adminFile, DefaultProjectDirectory: root, RuntimeFactory: func(hostedpi.Config) application.HostedPiRuntime { return runtime }}
	daemon, err := service.StartConfigured(context.Background(), socket, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	contents, _ := os.ReadFile(adminFile)
	var stored struct {
		Credential string `json:"credential_b64"`
	}
	_ = json.Unmarshal(contents, &stored)
	credential, _ := base64.StdEncoding.DecodeString(stored.Credential)
	startDone := make(chan *subagentsv1.Envelope, 1)
	go func() {
		startDone <- request(t, socket, &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: "deadline-start", DeadlineUnixMillis: time.Now().Add(80 * time.Millisecond).UnixMilli(), SessionCredential: credential, Payload: &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: "deadline-agent", ProjectDirectory: root}}})
	}()
	select {
	case <-runtime.started:
	case <-time.After(time.Second):
		t.Fatal("deadline START did not publish runtime start")
	}
	response := (<-startDone).GetHostedAdminResponse()
	if response == nil || response.GetAccepted() {
		t.Fatalf("deadline START unexpectedly completed synchronously: %#v", response)
	}
	close(runtime.release)
	adminStatus := func() *subagentsv1.HostedAdminResponse {
		return request(t, socket, &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 2, RequestId: time.Now().String(), DeadlineUnixMillis: time.Now().Add(time.Second).UnixMilli(), SessionCredential: credential, Payload: &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_STATUS, AgentId: "deadline-agent", ProjectDirectory: root}}}).GetHostedAdminResponse()
	}
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		status := adminStatus()
		if status.GetAccepted() && status.GetRuntime().GetState() == subagentsv1.HostedPiRuntimeBinding_STATE_STARTING && status.GetAttachTarget() != "" {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("published AgentActor did not survive START client deadline: %#v", adminStatus())
}

func TestHostedAdminSerializesStopDuringStart(t *testing.T) {
	root := privateTempDir(t)
	socket := filepath.Join(root, "runtime", "control.sock")
	adminFile := filepath.Join(root, "admin", "credential.json")
	runtime := &launchAwareRuntime{started: make(chan struct{}), release: make(chan struct{})}
	config := service.HostedAdminConfig{Enabled: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge.ts", StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: adminFile, DefaultProjectDirectory: root, RuntimeFactory: func(hostedpi.Config) application.HostedPiRuntime { return runtime }}
	daemon, err := service.StartConfigured(context.Background(), socket, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	contents, _ := os.ReadFile(adminFile)
	var stored struct {
		Credential string `json:"credential_b64"`
	}
	_ = json.Unmarshal(contents, &stored)
	credential, _ := base64.StdEncoding.DecodeString(stored.Credential)
	adminEnvelope := func(operation subagentsv1.HostedAdminRequest_Operation) *subagentsv1.Envelope {
		return &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: time.Now().String(), DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli(), SessionCredential: credential, Payload: &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: operation, AgentId: "serialized-agent", ProjectDirectory: root}}}
	}
	startedResult, stoppedResult := make(chan *subagentsv1.Envelope, 1), make(chan *subagentsv1.Envelope, 1)
	go func() {
		startedResult <- request(t, socket, adminEnvelope(subagentsv1.HostedAdminRequest_OPERATION_START))
	}()
	select {
	case <-runtime.started:
	case <-time.After(time.Second):
		t.Fatal("START effect did not begin")
	}
	go func() {
		stoppedResult <- request(t, socket, adminEnvelope(subagentsv1.HostedAdminRequest_OPERATION_STOP))
	}()
	select {
	case <-stoppedResult:
		t.Fatal("STOP bypassed in-flight START serialization")
	case <-time.After(50 * time.Millisecond):
	}
	close(runtime.release)
	if response := <-startedResult; !response.GetHostedAdminResponse().GetAccepted() {
		t.Fatalf("serialized START failed: %#v", response)
	}
	if response := <-stoppedResult; !response.GetHostedAdminResponse().GetAccepted() {
		t.Fatalf("serialized STOP failed: %#v", response)
	}
	if files, _ := filepath.Glob(filepath.Join(root, "credentials", "*.json")); len(files) != 0 {
		t.Fatalf("START/STOP race leaked credentials: %v", files)
	}
}

func TestDaemonStopCancelsInflightStartBeforeRuntimeSnapshot(t *testing.T) {
	root := privateTempDir(t)
	socket := filepath.Join(root, "runtime", "control.sock")
	adminFile := filepath.Join(root, "admin", "credential.json")
	runtime := &launchAwareRuntime{started: make(chan struct{}), release: make(chan struct{}), canceled: make(chan struct{})}
	config := service.HostedAdminConfig{Enabled: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge.ts", StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: adminFile, DefaultProjectDirectory: root, RuntimeFactory: func(hostedpi.Config) application.HostedPiRuntime { return runtime }}
	daemon, err := service.StartConfigured(context.Background(), socket, config)
	if err != nil {
		t.Fatal(err)
	}
	contents, _ := os.ReadFile(adminFile)
	var stored struct {
		Credential string `json:"credential_b64"`
	}
	_ = json.Unmarshal(contents, &stored)
	credential, _ := base64.StdEncoding.DecodeString(stored.Credential)
	envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: "concurrent-shutdown-start", DeadlineUnixMillis: time.Now().Add(10 * time.Second).UnixMilli(), SessionCredential: credential, Payload: &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: "shutdown-agent", ProjectDirectory: root}}}
	requestDone := make(chan error, 1)
	go func() {
		connection, err := net.Dial("unix", socket)
		if err == nil {
			err = protocol.WriteEnvelope(connection, envelope)
		}
		if err == nil {
			_, err = protocol.ReadEnvelope(connection)
		}
		if connection != nil {
			_ = connection.Close()
		}
		requestDone <- err
	}()
	select {
	case <-runtime.started:
	case <-time.After(time.Second):
		t.Fatal("in-flight START did not reach runtime")
	}
	stopCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := daemon.Stop(stopCtx); err != nil {
		t.Fatal(err)
	}
	select {
	case <-runtime.canceled:
	case <-time.After(time.Second):
		t.Fatal("daemon Stop did not cancel actor-managed START")
	}
	select {
	case <-requestDone:
	case <-time.After(time.Second):
		t.Fatal("shutdown did not settle in-flight admin connection")
	}
	if files, _ := filepath.Glob(filepath.Join(root, "credentials", "*.json")); len(files) != 0 {
		t.Fatalf("daemon START/Stop race leaked credentials: %v", files)
	}
	if records, _ := filepath.Glob(filepath.Join(root, "state", "*.json")); len(records) != 0 {
		t.Fatalf("daemon START/Stop race leaked bindings: %v", records)
	}
}

func TestHostedAdminRemainsDisabledByDefault(t *testing.T) {
	path := privateTempDir(t) + "/disabled.sock"
	daemon, err := service.Start(context.Background(), path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	response := request(t, path, &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: "disabled", DeadlineUnixMillis: time.Now().Add(time.Second).UnixMilli(), SessionCredential: []byte(strings.Repeat("x", 32)), Payload: &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: "agent"}}})
	if response.GetProtocolError() == nil {
		t.Fatal("hosted admin unexpectedly active by default")
	}
}
