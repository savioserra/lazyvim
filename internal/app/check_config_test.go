package app

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestStyluaBatchCommandUsesCallWithoutCmdQuoteRewriting(t *testing.T) {
	arguments := styluaBatchArguments()
	joined := strings.Join(arguments, " ")
	if strings.Contains(joined, " /s ") || !strings.Contains(joined, `call "%LAZYVIM_STYLUA%"`) {
		t.Fatalf("unexpected cmd.exe arguments: %v", arguments)
	}
}

func TestCheckConfigTargetRequiresCustomXDGLink(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix XDG link behavior")
	}
	home := t.TempDir()
	expected := filepath.Join(home, ".config", "nvim")
	if err := os.MkdirAll(expected, 0o755); err != nil {
		t.Fatal(err)
	}
	custom := filepath.Join(home, "xdg", "nvim")
	if err := os.MkdirAll(custom, 0o755); err != nil {
		t.Fatal(err)
	}
	application := &App{paths: Paths{Home: home, NvimConfig: custom}}
	if err := application.checkConfigTarget(); err == nil || !strings.Contains(err.Error(), "expected") {
		t.Fatalf("wrong custom target passed validation: %v", err)
	}
	if err := os.RemoveAll(custom); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(custom), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(expected, custom); err != nil {
		t.Fatal(err)
	}
	if err := application.checkConfigTarget(); err != nil {
		t.Fatal(err)
	}
}
