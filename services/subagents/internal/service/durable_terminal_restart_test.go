package service

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	durablestate "github.com/savioserra/lazyvim/services/subagents/internal/state"
)

func TestReconcileDurableHostedReloadsPersistedTerminalRecords(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	stateDir := filepath.Join(root, "state")
	store, err := durablestate.New(filepath.Join(stateDir, "registrations"))
	if err != nil {
		t.Fatal(err)
	}
	terminal := func(id string) application.DurableHostedRecord {
		return application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, OwnerUID: os.Getuid(), AgentID: id, AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: id}, AllowedCapabilities: []string{"observe", "send", "ask", "prompt", "control_abort", "control_shutdown"}, Retention: "bounded", Recovery: "terminal-reattach", Binding: application.InactiveHostedPiRuntimeBinding(), AgentState: application.DurableAgentState{SourceOutbox: []application.DurableActorTaskOutboxItem{{TaskID: id + ":dedupe:chain:1", Target: application.CommunicationPeer{StableID: "target-agent"}, RequestID: "request", DedupeID: "dedupe", ChainID: "chain", RequiredCapability: "send", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Hour), HopLimit: 8, Mode: application.BridgeMessageTell, Payload: []byte("pending"), State: "pending_credit"}}}}
	}
	// Two persisted terminal records model a daemon restart after local
	// credit-admission activity: both reload without hosted runtime paths and
	// without colliding on an empty project directory.
	for _, id := range []string{"client:terminal-1", "client:terminal-2"} {
		if err := store.Save(context.Background(), terminal(id)); err != nil {
			t.Fatal(err)
		}
	}
	listener, err := net.Listen("unix", filepath.Join(root, "control.sock"))
	if err != nil {
		t.Fatal(err)
	}
	daemon, err := startWithListener(context.Background(), listener, HostedAdminConfig{Enabled: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge", StateDirectory: stateDir, PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: filepath.Join(root, "admin.json"), DefaultProjectDirectory: root})
	if err != nil {
		t.Fatalf("restart with persisted terminal records failed: %v", err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	for _, id := range []string{"client:terminal-1", "client:terminal-2"} {
		response, err := daemon.system.NoSender().Ask(context.Background(), daemon.agentRegistry, &application.ResolveAgentControl{AgentID: id}, 2*time.Second)
		if err != nil {
			t.Fatalf("resolve reloaded terminal agent %s: %v", id, err)
		}
		resolved, ok := response.(*application.AgentControlPID)
		if !ok || !resolved.Found {
			t.Fatalf("reloaded terminal agent %s was not registered: %#v", id, response)
		}
	}
	records, err := daemon.durableStore.LoadAll(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(records) != 2 {
		t.Fatalf("terminal records must survive restart reload without stale removal: %d records", len(records))
	}
}
