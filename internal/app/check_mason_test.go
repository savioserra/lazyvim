package app

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCheckMasonRequiresEveryLockedPackage(t *testing.T) {
	tests := []struct {
		name      string
		prepare   func(t *testing.T, packages string)
		wantError string
	}{
		{name: "missing packages root", wantError: "package directory is missing"},
		{name: "missing package", prepare: mkdirOnly, wantError: "locked Mason package is missing"},
		{name: "missing receipt", prepare: func(t *testing.T, packages string) {
			mkdirOnly(t, packages)
			mustMkdir(t, filepath.Join(packages, "stylua"))
		}, wantError: "has no receipt"},
		{name: "malformed receipt", prepare: func(t *testing.T, packages string) {
			writeReceiptBytes(t, packages, []byte("{"))
		}, wantError: "parse Mason receipt"},
		{name: "wrong package identity", prepare: func(t *testing.T, packages string) {
			writeReceipt(t, packages, "other", "v2.5.2")
		}, wantError: "identifies \"other\""},
		{name: "wrong version", prepare: func(t *testing.T, packages string) {
			writeReceipt(t, packages, "stylua", "v1.0.0")
		}, wantError: "lockfile requires v2.5.2"},
		{name: "matching package", prepare: func(t *testing.T, packages string) {
			writeReceipt(t, packages, "stylua", "v2.5.2")
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			repository := t.TempDir()
			lockPath := filepath.Join(repository, "home", "dot_config", "nvim", "mason-lock.json")
			mustMkdir(t, filepath.Dir(lockPath))
			if err := os.WriteFile(lockPath, []byte("{\"stylua\":\"v2.5.2\"}\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			data := t.TempDir()
			packages := filepath.Join(data, "mason", "packages")
			if test.prepare != nil {
				test.prepare(t, packages)
			}
			application := &App{repoRoot: repository, paths: Paths{NvimData: data}, out: io.Discard, err: io.Discard}
			err := application.checkMason()
			if test.wantError == "" {
				if err != nil {
					t.Fatal(err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), test.wantError) {
				t.Fatalf("got %v, want error containing %q", err, test.wantError)
			}
		})
	}
}

func mkdirOnly(t *testing.T, path string) {
	t.Helper()
	mustMkdir(t, path)
}

func mustMkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

func writeReceipt(t *testing.T, packages, name, version string) {
	t.Helper()
	receipt := masonReceipt{Name: name}
	receipt.Source.ID = "pkg:github/example/stylua@" + version
	content, err := json.Marshal(receipt)
	if err != nil {
		t.Fatal(err)
	}
	writeReceiptBytes(t, packages, content)
}

func writeReceiptBytes(t *testing.T, packages string, content []byte) {
	t.Helper()
	path := filepath.Join(packages, "stylua", "mason-receipt.json")
	mustMkdir(t, filepath.Dir(path))
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatal(err)
	}
}
