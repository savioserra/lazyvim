package app

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRestoreMasonUsesIsolatedConfigAndVerifiesReceipts(t *testing.T) {
	repository := t.TempDir()
	lockPath := filepath.Join(repository, "home", "dot_config", "nvim", "mason-lock.json")
	if err := os.MkdirAll(filepath.Dir(lockPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(lockPath, []byte("{\"stylua\":\"v2.5.2\"}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	data := t.TempDir()
	writeReceipt(t, filepath.Join(data, "mason", "packages"), "stylua", "v1.0.0")
	if err := os.MkdirAll(filepath.Join(data, "lazy", "mason.nvim"), 0o755); err != nil {
		t.Fatal(err)
	}
	runner := &recordingRunner{}
	application := &App{
		repoRoot: repository,
		paths:    Paths{NvimData: data, Home: t.TempDir()},
		out:      io.Discard,
		err:      io.Discard,
		runner:   runner,
	}
	err := application.restoreMason(context.Background(), "nvim")
	if err == nil || !strings.Contains(err.Error(), "verify restored Mason packages") {
		t.Fatalf("got %v, want post-install receipt verification failure", err)
	}
	arguments := strings.Join(runner.command.Args, " ")
	if !strings.Contains(arguments, "--headless -u NONE") || !strings.Contains(arguments, "plugin/mason.lua") {
		t.Fatalf("Mason was not run with an isolated config: %s", arguments)
	}
	if strings.Contains(arguments, "Lazy load") {
		t.Fatalf("Mason restore loaded the full editor configuration: %s", arguments)
	}
}
