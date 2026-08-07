package app

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func TestRestorePluginsJoinsPrimaryAndRollbackFailures(t *testing.T) {
	root := t.TempDir()
	committed := filepath.Join(root, "home", "dot_config", "nvim", "lazy-lock.json")
	if err := os.MkdirAll(filepath.Dir(committed), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(committed, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	primary := errors.New("neovim failed")
	rollback := errors.New("rollback failed")
	copies := 0
	application := &App{
		repoRoot: root,
		paths:    Paths{Home: filepath.Join(root, "target-home")},
		out:      io.Discard,
		err:      io.Discard,
		runner:   &recordingRunner{err: primary},
		copyFile: func(source, destination string, mode os.FileMode) error {
			copies++
			if copies > 1 {
				return rollback
			}
			return copyFile(source, destination, mode)
		},
	}
	err := application.restorePlugins(context.Background(), "nvim")
	if !errors.Is(err, primary) || !errors.Is(err, rollback) {
		t.Fatalf("got %v, want both primary and rollback failures", err)
	}
}
