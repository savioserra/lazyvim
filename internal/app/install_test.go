package app

import (
	"archive/zip"
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/internal/config"
)

func TestInstallReleaseStagesAndBacksUpExistingTarget(t *testing.T) {
	root := t.TempDir()
	archivePath := filepath.Join(root, "tool.zip")
	expected := "tool"
	if runtime.GOOS == "windows" {
		expected += ".exe"
	}
	createZipFixture(t, archivePath, expected, []byte("new binary"))
	platform, err := config.PlatformFor(runtime.GOOS, runtime.GOARCH)
	if err != nil {
		if runtime.GOOS == "linux" && runtime.GOARCH != "amd64" {
			t.Skip(err)
		}
		t.Fatal(err)
	}
	release := config.Release{
		Name: "tool", Version: "1.0.0", Platform: platform,
		URL: "https://example.invalid/tool.zip", SHA256: strings.Repeat("a", 64),
		ArchiveName: "tool.zip", ArchiveKind: config.ArchiveZip,
		TargetName: "tool-1.0.0", ExpectedBinary: expected,
	}
	opt := filepath.Join(root, "opt")
	target := filepath.Join(opt, release.TargetName)
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	mustWriteFile(t, filepath.Join(target, expected), []byte("old binary"), 0o755)
	downloader := &fakeDownloader{path: archivePath}
	application := discardApp()
	application.paths = Paths{Home: filepath.Join(root, "home"), Opt: opt, State: filepath.Join(root, "state")}
	application.downloader = downloader
	application.now = func() time.Time { return time.Date(2026, 8, 7, 19, 0, 0, 0, time.UTC) }
	installed, err := application.installRelease(context.Background(), release)
	if err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(filepath.Join(installed, expected))
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "new binary" {
		t.Fatalf("got %q", content)
	}
	marker, err := os.ReadFile(filepath.Join(installed, ".lazyvim-release"))
	if err != nil || strings.TrimSpace(string(marker)) != release.ReleaseIdentity() {
		t.Fatalf("invalid release marker %q: %v", marker, err)
	}
	backedUp := false
	err = filepath.WalkDir(filepath.Join(root, "state", "backups"), func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if !entry.IsDir() && entry.Name() == filepath.Base(expected) {
			content, readErr := os.ReadFile(path)
			if readErr == nil && string(content) == "old binary" {
				backedUp = true
			}
		}
		return nil
	})
	if err != nil || !backedUp {
		t.Fatalf("existing release was not backed up: %v", err)
	}
}

func createZipFixture(t *testing.T, path, name string, content []byte) {
	t.Helper()
	file, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	header := &zip.FileHeader{Name: name, Method: zip.Store}
	header.SetMode(0o755)
	member, err := writer.CreateHeader(header)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := member.Write(content); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
}
