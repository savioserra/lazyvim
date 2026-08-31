package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	durablestate "github.com/savioserra/lazyvim/services/subagents/internal/state"
)

func quarantineRestartRecord(id string) application.DurableHostedRecord {
	return application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, OwnerUID: os.Getuid(), AgentID: id, AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: id}, AllowedCapabilities: []string{"observe", "send"}, Retention: "bounded", Recovery: "terminal-reattach", Binding: application.InactiveHostedPiRuntimeBinding()}
}

func poisonedRecordName(id string) string {
	sum := sha256.Sum256([]byte(id))
	return hex.EncodeToString(sum[:16]) + ".json"
}

// TestReconcileDurableHostedQuarantinesPoisonedRecordsWithoutBlockingStartup
// guards the daemon crash-loop incident: any invalid or unusable durable record
// must be quarantined per-record (moved aside with a degraded projection)
// while every valid record still loads and the daemon always starts.
func TestReconcileDurableHostedQuarantinesPoisonedRecordsWithoutBlockingStartup(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	stateDir := filepath.Join(root, "state")
	registrations := filepath.Join(stateDir, "registrations")
	store, err := durablestate.New(registrations)
	if err != nil {
		t.Fatal(err)
	}
	// Valid terminal records that must load.
	for _, id := range []string{"client:live-1", "client:live-2"} {
		if err := store.Save(context.Background(), quarantineRestartRecord(id)); err != nil {
			t.Fatal(err)
		}
	}
	// Poisoned entry 1: undecodable record file for another agent.
	if err := os.WriteFile(filepath.Join(registrations, poisonedRecordName("client:corrupt")), []byte("{\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	// Poisoned entry 2: store-valid terminal record whose registration is
	// invalid (empty retention), rejected only at reconcile.
	unusable := quarantineRestartRecord("client:unusable")
	unusable.Retention = ""
	if err := store.Save(context.Background(), unusable); err != nil {
		t.Fatalf("store rejected the reconcile-level poison setup: %v", err)
	}
	listener, err := net.Listen("unix", filepath.Join(root, "control.sock"))
	if err != nil {
		t.Fatal(err)
	}
	daemon, err := startWithListener(context.Background(), listener, HostedAdminConfig{Enabled: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge", StateDirectory: stateDir, PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: filepath.Join(root, "admin.json"), DefaultProjectDirectory: root})
	if err != nil {
		t.Fatalf("daemon must start despite poisoned durable records: %v", err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	for _, id := range []string{"client:live-1", "client:live-2"} {
		response, err := daemon.system.NoSender().Ask(context.Background(), daemon.agentRegistry, &application.ResolveAgentControl{AgentID: id}, 2*time.Second)
		if err != nil {
			t.Fatalf("resolve valid agent %s: %v", id, err)
		}
		resolved, ok := response.(*application.AgentControlPID)
		if !ok || !resolved.Found {
			t.Fatalf("valid agent %s was not loaded alongside quarantined records: %#v", id, response)
		}
	}
	for _, id := range []string{"client:corrupt", "client:unusable"} {
		response, err := daemon.system.NoSender().Ask(context.Background(), daemon.agentRegistry, &application.ResolveAgentControl{AgentID: id}, 2*time.Second)
		if err != nil {
			t.Fatal(err)
		}
		if resolved, ok := response.(*application.AgentControlPID); ok && resolved.Found {
			t.Fatalf("poisoned agent %s must not register", id)
		}
	}
	// Both poisoned records moved aside into the quarantine directory.
	quarantineDir := filepath.Join(registrations, "quarantine")
	for _, id := range []string{"client:corrupt", "client:unusable"} {
		name := poisonedRecordName(id)
		if _, err := os.Stat(filepath.Join(quarantineDir, name)); err != nil {
			t.Fatalf("poisoned record %s was not quarantined: %v", id, err)
		}
		if _, err := os.Stat(filepath.Join(quarantineDir, name+".reason")); err != nil {
			t.Fatalf("quarantined record %s lacks an operator reason: %v", id, err)
		}
	}
	// The degraded projection is fail-closed: health reports quarantine.
	health, err := daemon.Health(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if health.Ready || health.Status == "" {
		t.Fatalf("quarantined durable state must degrade health: %#v", health)
	}
	records, _, err := daemon.durableStore.LoadAllWithQuarantine(context.Background())
	if err != nil || len(records) != 2 {
		t.Fatalf("usable record set after quarantine: %d records, err %v", len(records), err)
	}
}

// TestReconcileDurableHostedHealsLegacyTerminalBindingMetadata guards the
// writer/validator mismatch incident: terminal records already on disk whose
// binding carries live display metadata (the legacy writer output) must heal
// at reconcile instead of failing registration and crash-looping the daemon.
func TestReconcileDurableHostedHealsLegacyTerminalBindingMetadata(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	stateDir := filepath.Join(root, "state")
	store, err := durablestate.New(filepath.Join(stateDir, "registrations"))
	if err != nil {
		t.Fatal(err)
	}
	legacy := quarantineRestartRecord("client:legacy-terminal")
	legacy.Binding.DisplayName = "TERMINAL PI"
	legacy.Binding.Role = "TERMINAL PI"
	if err := store.Save(context.Background(), legacy); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", filepath.Join(root, "control.sock"))
	if err != nil {
		t.Fatal(err)
	}
	daemon, err := startWithListener(context.Background(), listener, HostedAdminConfig{Enabled: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge", StateDirectory: stateDir, PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), AdminCredentialFile: filepath.Join(root, "admin.json"), DefaultProjectDirectory: root})
	if err != nil {
		t.Fatalf("daemon must start and heal legacy terminal metadata: %v", err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	response, err := daemon.system.NoSender().Ask(context.Background(), daemon.agentRegistry, &application.ResolveAgentControl{AgentID: "client:legacy-terminal"}, 2*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	resolved, ok := response.(*application.AgentControlPID)
	if !ok || !resolved.Found {
		t.Fatalf("legacy terminal record was not healed and registered: %#v", response)
	}
	records, _, err := daemon.durableStore.LoadAllWithQuarantine(context.Background())
	if err != nil || len(records) != 1 {
		t.Fatalf("healed record must remain durable: %d records, err %v", len(records), err)
	}
}
