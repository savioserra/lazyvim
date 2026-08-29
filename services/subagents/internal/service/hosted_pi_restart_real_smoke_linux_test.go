//go:build linux

package service

import (
	"context"
	"errors"
	"fmt"
	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/hostedpi"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestRealDaemonManagedRestartAdoptsHostedPiAndDurableDelivery(t *testing.T) {
	if os.Getenv("RUN_REAL_HOSTED_PI_SMOKE") != "1" {
		t.Skip("set RUN_REAL_HOSTED_PI_SMOKE=1")
	}
	tmux, err := exec.LookPath("tmux")
	if err != nil {
		t.Fatal("tmux unavailable")
	}
	pi, err := exec.LookPath("pi")
	if err != nil {
		t.Fatal("Pi unavailable")
	}
	repository, _ := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	bridge := filepath.Join(repository, "home", "dot_pi", "private_agent", "extensions", "hosted-pi-bridge", "index.ts")
	root := t.TempDir()
	_ = os.Chmod(root, 0o700)
	tmuxRoot, err := os.MkdirTemp("/tmp", "ws-restart-")
	if err != nil {
		t.Fatal(err)
	}
	_ = os.Chmod(tmuxRoot, 0o700)
	t.Setenv("TMUX_TMPDIR", tmuxRoot)
	t.Cleanup(func() { _ = os.RemoveAll(tmuxRoot) })
	server := fmt.Sprintf("ws-hosted-restart-%d", os.Getpid())
	tmuxConfig := filepath.Join(root, "tmux.conf")
	_ = os.WriteFile(tmuxConfig, []byte("set -g status off\n"), 0o600)
	if output, err := exec.Command(tmux, "-L", server, "-f", tmuxConfig, "new-session", "-d", "-s", "foreign", "/bin/sleep", "90").CombinedOutput(); err != nil {
		t.Fatalf("foreign tmux: %v %s", err, output)
	}
	t.Cleanup(func() { _ = exec.Command(tmux, "-L", server, "kill-server").Run() })
	socket := filepath.Join(root, "runtime", "control.sock")
	cfg := HostedAdminConfig{Enabled: true, TmuxBinary: tmux, PiBinary: pi, BridgeExtension: bridge, ServerName: server, TmuxConfig: tmuxConfig, StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: filepath.Join(root, "admin", "credential.json"), DefaultProjectDirectory: repository, TrustProject: true}
	daemon, err := StartConfigured(context.Background(), socket, cfg)
	if err != nil {
		t.Fatal(err)
	}
	binding, err := daemon.startHostedAgent(context.Background(), &subagentsv1.HostedAdminRequest{AgentId: "restart-agent", ProjectDirectory: repository, TrustProject: true})
	if err != nil {
		t.Fatal(err)
	}
	attachTarget, history := binding.TmuxSessionID, binding.PiSessionDirectory
	deadline := time.Now().Add(15 * time.Second)
	for {
		binding, err = daemon.hostedStatus(context.Background(), "restart-agent")
		if err == nil && binding.BridgeReady {
			break
		}
		if time.Now().After(deadline) {
			durable, durableErr := daemon.durableStore.LoadAll(context.Background())
			t.Fatalf("bridge not ready before crash: binding=%#v status=%v durable=%#v durableErr=%v", binding, err, durable, durableErr)
		}
		time.Sleep(100 * time.Millisecond)
	}
	source := application.OpenSession{SessionID: "source", GenerationID: "one", Caller: "hosted:source", Credential: []byte("12345678901234567890123456789012"), Capabilities: []string{"observe", "send"}, ExpiresAt: time.Now().Add(time.Hour)}
	if err = daemon.OpenSession(context.Background(), source); err != nil {
		t.Fatal(err)
	}
	envelope := func(payload any) *subagentsv1.Envelope {
		request := &subagentsv1.Envelope{ProtocolMajor: 1, SessionId: source.SessionID, GenerationId: source.GenerationID, CallerIdentity: source.Caller, SessionCredential: source.Credential, RequestId: fmt.Sprint(time.Now().UnixNano()), DeadlineUnixMillis: time.Now().Add(5 * time.Second).UnixMilli()}
		switch value := payload.(type) {
		case *subagentsv1.Envelope_AttachRequest:
			request.Payload = value
		case *subagentsv1.Envelope_ActorMessageRequest:
			request.Payload = value
		}
		return request
	}
	attached := daemon.dispatch(envelope(&subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: "restart-agent", RequestedCapabilities: []string{"send"}}})).GetAttachResponse()
	message := envelope(&subagentsv1.Envelope_ActorMessageRequest{ActorMessageRequest: &subagentsv1.ActorMessageRequest{Mode: subagentsv1.ActorMessageRequest_MODE_TELL, Target: "restart-agent", BoundedPayload: []byte("durable no-provider delivery"), DedupeId: "restart-dedupe", ChainId: "restart-chain", HopLimit: 4, SourceMutationSequence: 1}})
	message.AgentHandle, message.AgentFence = attached.AgentHandle, attached.Fence
	if result := daemon.dispatch(message).GetActorMessageResponse(); result == nil || !result.Accepted {
		t.Fatalf("durable delivery not accepted: %#v", result)
	}
	records, loadErr := daemon.durableStore.LoadAll(context.Background())
	if loadErr != nil || len(records) != 1 || len(records[0].AgentState.BridgeDeliveries) != 1 {
		t.Fatalf("accepted delivery was not durably pending before crash: %#v %v", records, loadErr)
	}
	restartCtx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	if err = daemon.Stop(restartCtx); err != nil {
		cancel()
		t.Fatal(err)
	}
	cancel()
	if err = exec.Command(tmux, "-L", server, "has-session", "-t", attachTarget).Run(); err != nil {
		t.Fatal("managed daemon stop destroyed the hosted session before adoption")
	}
	daemon2, err := StartConfigured(context.Background(), socket, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		_ = daemon2.Stop(ctx)
	})
	deadline = time.Now().Add(15 * time.Second)
	for {
		binding, err = daemon2.hostedStatus(context.Background(), "restart-agent")
		if err == nil && binding.BridgeReady {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("adopted bridge not ready: %#v %v", binding, err)
		}
		time.Sleep(100 * time.Millisecond)
	}
	if binding.TmuxSessionID != attachTarget || binding.PiSessionDirectory != history {
		t.Fatalf("adoption changed exact target/history: %#v", binding)
	}
	deadline = time.Now().Add(5 * time.Second)
	for {
		records, loadErr = daemon2.durableStore.LoadAll(context.Background())
		if loadErr == nil && len(records) == 1 && len(records[0].AgentState.BridgeDeliveries) == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("reconnected bridge did not durably ACK pending delivery: %#v %v", records, loadErr)
		}
		time.Sleep(50 * time.Millisecond)
	}
	later := application.OpenSession{SessionID: "later", GenerationID: "two", Caller: "human", Credential: []byte("abcdefghijklmnopqrstuvwxyzABCDEF"), Capabilities: []string{"observe"}, ExpiresAt: time.Now().Add(time.Hour)}
	if err = daemon2.OpenSession(context.Background(), later); err != nil {
		t.Fatal(err)
	}
	stopCtx, stopCancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer stopCancel()
	if _, err = daemon2.stopHostedAgent(stopCtx, "restart-agent"); err != nil {
		t.Fatal(err)
	}
	if err = exec.Command(tmux, "-L", server, "has-session", "-t", binding.TmuxSessionID).Run(); err == nil {
		t.Fatal("adopted exact session survived stop")
	}
	if err = exec.Command(tmux, "-L", server, "has-session", "-t", "foreign").Run(); err != nil {
		t.Fatal("foreign session was changed")
	}
	if records, err = daemon2.durableStore.LoadAll(context.Background()); err != nil || len(records) != 0 {
		t.Fatalf("durable registration survived exact STOP: %#v %v", records, err)
	}
	if _, err = hostedpi.LoadOwnershipBinding(cfg.StateDirectory, binding.RuntimeID); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("exact ownership record survived STOP: %v", err)
	}
	if credentials, globErr := filepath.Glob(filepath.Join(cfg.CredentialDirectory, "*.json")); globErr != nil || len(credentials) != 0 {
		t.Fatalf("hosted bridge credential survived STOP: %v %v", credentials, globErr)
	}
}
