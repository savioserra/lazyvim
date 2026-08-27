//go:build linux || darwin

package state

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

func testRecord(root string) application.DurableHostedRecord {
	return application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, OwnerUID: os.Getuid(), AgentID: "agent", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: "runtime"}, AllowedCapabilities: []string{"send"}, Retention: "explicit", Recovery: "owned-binding-v2", Session: application.DurableHostedSession{SessionID: "session", GenerationID: "generation", Caller: "hosted:agent", Capabilities: []string{"send"}, Persistent: true, CredentialFile: filepath.Join(root, "credentials", "agent.json")}, LaunchSpec: application.HostedPiLaunchSpec{AgentID: "agent", RuntimeID: "runtime", Incarnation: 1, TmuxSession: "tmux", TmuxWindow: "pi", PiSessionDirectory: filepath.Join(root, "sessions", "agent"), PiSessionName: "hosted-agent"}, RuntimeConfig: application.DurableRuntimeConfig{ProjectDirectory: root}, Binding: application.HostedPiRuntimeBinding{RuntimeID: "runtime", Incarnation: 1}}
}
func TestStoreAtomicCrashPointsAndSecureEnumeration(t *testing.T) {
	for _, point := range []CrashPoint{CrashBeforeRename, CrashAfterRename, CrashBeforeReceipt} {
		t.Run(string(point), func(t *testing.T) {
			root := t.TempDir()
			_ = os.Chmod(filepath.Dir(root), 0o700)
			_ = os.Chmod(root, 0o700)
			dir := filepath.Join(root, "state")
			s, err := New(dir)
			if err != nil {
				t.Fatal(err)
			}
			s.Crash = func(actual CrashPoint) error {
				if actual == point {
					return errors.New("crash")
				}
				return nil
			}
			if err = s.Save(context.Background(), testRecord(root)); err == nil {
				t.Fatal("crash point succeeded")
			}
			loaded, loadErr := s.LoadAll(context.Background())
			if point == CrashBeforeRename {
				if loadErr != nil || len(loaded) != 0 {
					t.Fatalf("pre-rename published state: %#v %v", loaded, loadErr)
				}
				entries, err := os.ReadDir(dir)
				if err != nil || len(entries) != 0 {
					t.Fatalf("interrupted temporary was not securely reconciled: %#v %v", entries, err)
				}
			} else if loadErr != nil || len(loaded) != 1 {
				t.Fatalf("post-rename state was not recoverable: %#v %v", loaded, loadErr)
			}
		})
	}
	root := t.TempDir()
	_ = os.Chmod(filepath.Dir(root), 0o700)
	_ = os.Chmod(root, 0o700)
	s, _ := New(filepath.Join(root, "state"))
	if err := s.Save(context.Background(), testRecord(root)); err != nil {
		t.Fatal(err)
	}
	name := recordName("agent")
	if err := os.Chmod(filepath.Join(s.Directory, name), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := s.LoadAll(context.Background()); err == nil {
		t.Fatal("widened record accepted")
	}
	_ = os.Remove(filepath.Join(s.Directory, name))
	if err := os.Symlink("/etc/passwd", filepath.Join(s.Directory, name)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.LoadAll(context.Background()); err == nil {
		t.Fatal("symlink record accepted")
	}
	_ = os.Remove(filepath.Join(s.Directory, name))
	if err := os.WriteFile(filepath.Join(s.Directory, name), []byte("{\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := s.LoadAll(context.Background()); err == nil {
		t.Fatal("corrupt record accepted")
	}
}
