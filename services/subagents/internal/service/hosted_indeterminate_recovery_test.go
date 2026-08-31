package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/hostedpi"
	durablestate "github.com/savioserra/lazyvim/services/subagents/internal/state"
)

func ownershipDigestHex(value string) string {
	digest := sha256.Sum256([]byte(value))
	return hex.EncodeToString(digest[:])
}

// fakeTmuxAlive reports the exact owned pane identity without needing a real
// tmux server: adoption then fails only at the process start-token proof, which
// is the ownership-indeterminate class under test.
func writeFakeTmux(t *testing.T, path, mode string, serverPID, sessionID, windowID, paneID, panePID, tty, serverToken, processToken string) {
	t.Helper()
	var script string
	switch mode {
	case "alive":
		script = fmt.Sprintf("#!/bin/sh\nprintf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t0\\tstatus:\\tsignal:\\n'\n", serverPID, sessionID, windowID, paneID, panePID, tty, ownershipDigestHex(serverToken), ownershipDigestHex(processToken))
	case "gone":
		script = "#!/bin/sh\necho \"no server running\" >&2\nexit 1\n"
	default:
		t.Fatalf("unknown fake tmux mode %q", mode)
	}
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

func indeterminateRecoveryRecord(root, agentID string) application.DurableHostedRecord {
	credentialFile := filepath.Join(root, "credentials", agentID+".json")
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.State = application.HostedPiRuntimeReady
	binding.RuntimeID = "runtime-recover"
	binding.Incarnation = 1
	binding.TmuxSession, binding.TmuxWindow, binding.TmuxPane = "ws-pi-recover", "pi", "%9"
	binding.TmuxSessionID, binding.TmuxWindowID = "$9", "@9"
	binding.TmuxServerPID, binding.PanePID = 4194304, 4194305
	binding.TmuxServerStartToken, binding.ProcessStartToken = "server-token", "process-token"
	binding.TTY = "/dev/pts/99"
	binding.PiSessionDirectory = filepath.Join(root, "sessions", agentID)
	binding.PiSessionName = "hosted-" + agentID
	return application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, OwnerUID: os.Getuid(), AgentID: agentID, AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: "runtime-recover"}, AllowedCapabilities: []string{"observe", "send"}, Retention: "explicit", Recovery: "owned-binding-v2", Session: application.DurableHostedSession{SessionID: "session-" + agentID, GenerationID: "generation-" + agentID, Caller: "hosted:" + agentID, Capabilities: []string{"observe", "send"}, Persistent: true, CredentialFile: credentialFile}, LaunchSpec: application.HostedPiLaunchSpec{AgentID: agentID, RuntimeID: "runtime-recover", Incarnation: 1, TmuxSession: "ws-pi-recover", TmuxWindow: "pi", PiSessionDirectory: filepath.Join(root, "sessions", agentID), PiSessionName: "hosted-" + agentID}, RuntimeConfig: application.DurableRuntimeConfig{ProjectDirectory: root}, Binding: binding}
}

// TestAdminStopRetiresIndeterminateRecordOnProvenAbsence guards the
// ownership-indeterminate deadlock incident: a dead hosted runtime with an
// indeterminate record used to block both admin STOP and same-name recreation
// with no operator recovery except manual file surgery. STOP must accept
// proven-absence evidence (tmux server gone, exact pane dead) and retire the
// record, while unproven liveness stays fail-closed indeterminate.
func TestAdminStopRetiresIndeterminateRecordOnProvenAbsence(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	const agentID = "recover-agent"
	record := indeterminateRecoveryRecord(root, agentID)
	if err := hostedpi.WriteCredentialFile(record.Session.CredentialFile, make([]byte, 32), true); err != nil {
		t.Fatal(err)
	}
	stateDir := filepath.Join(root, "state")
	store, err := durablestate.New(filepath.Join(stateDir, "registrations"))
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Save(context.Background(), record); err != nil {
		t.Fatal(err)
	}
	tmux := filepath.Join(root, "fake-tmux")
	writeFakeTmux(t, tmux, "alive", "4194304", "$9", "@9", "%9", "4194305", "/dev/pts/99", "server-token", "process-token")
	listener, err := net.Listen("unix", filepath.Join(root, "control.sock"))
	if err != nil {
		t.Fatal(err)
	}
	baseProcess := &clientProcess{binding: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, TmuxSessionID: "$client", TmuxWindowID: "@client", TmuxPane: "%client", PanePID: 42, ProcessStartToken: "start", TTY: "/dev/pts/42"}, done: make(chan error, 1)}
	daemon, err := startWithListener(context.Background(), listener, HostedAdminConfig{Enabled: true, TmuxBinary: tmux, PiBinary: "/pi", BridgeExtension: "/bridge", StateDirectory: stateDir, PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: filepath.Join(root, "admin.json"), DefaultProjectDirectory: root, TrustProject: true, RuntimeFactory: func(hostedpi.Config) application.HostedPiRuntime { return clientRuntime{process: baseProcess} }}, listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	daemon.hostedMu.Lock()
	_, indeterminate := daemon.hostedIndeterminate[agentID]
	daemon.hostedMu.Unlock()
	if !indeterminate {
		t.Fatal("ownership token mismatch did not mark the record indeterminate at reconcile")
	}
	stopCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// The pane identity is still observable, so absence is unproven and STOP
	// must stay fail-closed indeterminate instead of retiring the record.
	if _, err := daemon.stopHostedAgent(stopCtx, agentID); err == nil {
		t.Fatal("stop accepted without proven-absence evidence while the exact pane is still observable")
	}
	records, _, err := daemon.durableStore.LoadAllWithQuarantine(context.Background())
	if err != nil || len(records) != 1 {
		t.Fatalf("unproven stop must not retire the durable record: %d records, err %v", len(records), err)
	}
	// Proven absence: the tmux server is gone. STOP retires the record.
	writeFakeTmux(t, tmux, "gone", "", "", "", "", "", "", "", "")
	binding, err := daemon.stopHostedAgent(stopCtx, agentID)
	if err != nil {
		t.Fatalf("stop with proven-absence evidence must retire the record: %v", err)
	}
	if binding.State != application.HostedPiRuntimeStopped || binding.OwnershipIndeterminate {
		t.Fatalf("retired binding must be stopped and determinate: %#v", binding)
	}
	records, _, err = daemon.durableStore.LoadAllWithQuarantine(context.Background())
	if err != nil || len(records) != 0 {
		t.Fatalf("retired record must be removed from durable state: %d records, err %v", len(records), err)
	}
	daemon.hostedMu.Lock()
	_, indeterminate = daemon.hostedIndeterminate[agentID]
	daemon.hostedMu.Unlock()
	if indeterminate {
		t.Fatal("retirement left the indeterminate projection in place")
	}
	// Same-name recreation is unblocked after retirement.
	recreated, err := daemon.startHostedAgent(stopCtx, &subagentsv1.HostedAdminRequest{Operation: subagentsv1.HostedAdminRequest_OPERATION_START, AgentId: agentID, ProjectDirectory: root, TrustProject: true})
	if err != nil || recreated.RuntimeID == "" {
		t.Fatalf("same-name recreation after retirement failed: %#v %v", recreated, err)
	}
}
