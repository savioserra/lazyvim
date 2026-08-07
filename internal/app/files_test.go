package app

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestInstallSelfUsesInjectedExecutable(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "source-dotfiles")
	if err := os.WriteFile(source, []byte("binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	application := discardApp()
	application.paths = Paths{Opt: filepath.Join(root, "opt"), State: filepath.Join(root, "state"), Home: filepath.Join(root, "home")}
	application.executablePath = func() (string, error) { return source, nil }
	application.now = time.Now
	target, err := application.installSelf()
	if err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(target)
	if err != nil || string(content) != "binary" {
		t.Fatalf("installed CLI is invalid: %q, %v", content, err)
	}
	if info, err := os.Stat(target); err != nil || runtime.GOOS != "windows" && info.Mode().Perm()&0o111 == 0 {
		t.Fatalf("installed CLI is not executable: %v, %v", info, err)
	}
}

func TestBackupDirectoryUsesInjectedClock(t *testing.T) {
	state := t.TempDir()
	application := &App{paths: Paths{State: state}, now: func() time.Time {
		return time.Date(2026, time.August, 7, 18, 30, 0, 0, time.UTC)
	}}
	if got := application.backupDirectory(); !strings.Contains(got, "20260807T183000Z") {
		t.Fatalf("backup directory ignored injected clock: %s", got)
	}
}

func TestLinkBacksUpUnmanagedTarget(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix symlink behavior")
	}
	root := t.TempDir()
	source := filepath.Join(root, "source")
	target := filepath.Join(root, "home", ".local", "bin", "tool")
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatal(err)
	}
	mustWriteFile(t, source, []byte("managed"), 0o755)
	mustWriteFile(t, target, []byte("unmanaged"), 0o755)
	application := discardApp()
	application.paths = Paths{Home: filepath.Join(root, "home"), State: filepath.Join(root, "state")}
	application.now = time.Now
	if err := application.link(source, target); err != nil {
		t.Fatal(err)
	}
	resolved, err := filepath.EvalSymlinks(target)
	if err != nil || resolved != source {
		t.Fatalf("target was not linked: %s, %v", resolved, err)
	}
	backups, err := filepath.Glob(filepath.Join(root, "state", "backups", "*", ".local", "bin", "tool"))
	if err != nil || len(backups) != 1 {
		t.Fatalf("unmanaged target was not backed up: %v, %v", backups, err)
	}
}

func TestCopyFilePreservesDestinationWhenPublicationFails(t *testing.T) {
	directory := t.TempDir()
	source := filepath.Join(directory, "source")
	destination := filepath.Join(directory, "destination")
	if err := os.WriteFile(source, []byte("new"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(destination, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	publishError := errors.New("publish failed")
	err := copyFileWithReplace(source, destination, 0o600, func(_, _ string) error { return publishError })
	if !errors.Is(err, publishError) {
		t.Fatalf("got %v, want publication failure", err)
	}
	content, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "old" {
		t.Fatalf("destination changed to %q", content)
	}
}
