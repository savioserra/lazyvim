//go:build linux

package service_test

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/hostedpi"
	"github.com/savioserra/lazyvim/services/subagents/internal/protocol"
	"github.com/savioserra/lazyvim/services/subagents/internal/service"
)

type cancelGatedConcreteRuntime struct {
	delegate *hostedpi.Runtime
	started  chan struct{}
}

func (r *cancelGatedConcreteRuntime) Start(ctx context.Context, spec application.HostedPiLaunchSpec) (application.HostedPiOwnedProcess, error) {
	process, err := r.delegate.Start(ctx, spec)
	if err != nil {
		return nil, err
	}
	close(r.started)
	<-ctx.Done()
	cleanupCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if stopErr := process.Stop(cleanupCtx); stopErr != nil {
		return nil, stopErr
	}
	return nil, ctx.Err()
}

func buildHostedAdminPiHelper(t *testing.T, root string) string {
	t.Helper()
	source, binary := filepath.Join(root, "pi.go"), filepath.Join(root, "pi-helper")
	if err := os.WriteFile(source, []byte("package main\nimport \"time\"\nfunc main(){time.Sleep(time.Minute)}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command("go", "build", "-o", binary, source).CombinedOutput(); err != nil {
		t.Fatalf("build Pi helper: %v: %s", err, output)
	}
	return binary
}

func TestConcurrentAdminStartAndDaemonStopLeavesNoExternalOwnership(t *testing.T) {
	tmux, err := exec.LookPath("tmux")
	if err != nil {
		t.Skip("tmux unavailable")
	}
	root := privateTempDir(t)
	tmuxTmp, err := os.MkdirTemp("/tmp", "ws-admin-stop-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(tmuxTmp) })
	t.Setenv("TMUX_TMPDIR", tmuxTmp)
	server, tmuxConfig := "ws-admin-stop-race", filepath.Join(root, "tmux.conf")
	if err := os.WriteFile(tmuxConfig, []byte("set -g pane-base-index 1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	pi := buildHostedAdminPiHelper(t, root)
	socket, adminFile := filepath.Join(root, "runtime", "control.sock"), filepath.Join(root, "admin", "credential.json")
	started := make(chan struct{})
	config := service.HostedAdminConfig{Enabled: true, TmuxBinary: tmux, PiBinary: pi, BridgeExtension: filepath.Join(root, "bridge.ts"), ServerName: server, TmuxConfig: tmuxConfig, StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: adminFile, DefaultProjectDirectory: root, TrustProject: true}
	config.RuntimeFactory = func(runtimeConfig hostedpi.Config) application.HostedPiRuntime {
		return &cancelGatedConcreteRuntime{delegate: &hostedpi.Runtime{Config: runtimeConfig}, started: started}
	}
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
	envelope := &subagentsv1.Envelope{ProtocolMajor: 1, Sequence: 1, RequestId: "concrete-concurrent-start", DeadlineUnixMillis: time.Now().Add(10 * time.Second).UnixMilli(), SessionCredential: credential, Payload: &subagentsv1.Envelope_HostedAdminRequest{HostedAdminRequest: &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: "concrete-race", ProjectDirectory: root, TrustProject: true}}}
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
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("concrete hosted START did not create its external runtime")
	}
	stopCtx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	if err := daemon.Stop(stopCtx); err != nil {
		t.Fatal(err)
	}
	select {
	case <-requestDone:
	case <-time.After(time.Second):
		t.Fatal("admin connection did not settle")
	}
	digest := sha256.Sum256([]byte("concrete-race"))
	sessionName := "ws-pi-" + fmt.Sprintf("%x", digest[:6])
	if err := exec.Command(tmux, "-L", server, "has-session", "-t", sessionName).Run(); err == nil {
		t.Fatal("concurrent daemon Stop orphaned hosted tmux")
	}
	if files, _ := filepath.Glob(filepath.Join(root, "state", "*.json")); len(files) != 0 {
		t.Fatalf("binding records survived: %v", files)
	}
	if files, _ := filepath.Glob(filepath.Join(root, "credentials", "*.json")); len(files) != 0 {
		t.Fatalf("session credentials survived: %v", files)
	}
	_ = exec.Command(tmux, "-L", server, "kill-server").Run()
}
