package app

import (
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"

	"github.com/savioserra/lazyvim/internal/config"
)

func TestNewAcceptsInjectedHostDependencies(t *testing.T) {
	platform, err := config.CurrentPlatform()
	if err != nil {
		t.Fatal(err)
	}
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	paths := Paths{Home: t.TempDir(), State: t.TempDir()}
	runner := &recordingRunner{}
	downloader := &fakeDownloader{}
	application, err := New(Options{
		RepoRoot: root, Platform: &platform, Paths: &paths, Runner: runner, Downloader: downloader,
		In: nil, Out: io.Discard, Err: io.Discard,
	})
	if err != nil {
		t.Fatal(err)
	}
	if application.repoRoot != root || application.runner != runner || application.downloader != downloader {
		t.Fatal("injected dependencies were not retained")
	}
}

func TestSyncBuildArgumentsIncludeVersionMetadata(t *testing.T) {
	arguments := syncBuildArguments("v1.2.3", "/tmp/lazyvim")
	joined := strings.Join(arguments, " ")
	if !strings.Contains(joined, "internal/buildinfo.version=v1.2.3") || !strings.Contains(joined, "-o /tmp/lazyvim") {
		t.Fatalf("unexpected build arguments: %q", joined)
	}
}

func TestCommandEnvironmentPrependsManagedBin(t *testing.T) {
	inherited := filepath.Join(t.TempDir(), "system-bin")
	managed := filepath.Join(t.TempDir(), "managed-bin")
	t.Setenv("PATH", inherited)
	application := &App{paths: Paths{Bin: managed}}
	var actual string
	for _, entry := range application.commandEnvironment("tool") {
		name, value, _ := strings.Cut(entry, "=")
		if strings.EqualFold(name, "PATH") {
			actual = value
		}
	}
	expected := managed + string(os.PathListSeparator) + inherited
	if actual != expected {
		t.Fatalf("got PATH %q, want %q", actual, expected)
	}
}

func TestJoinCleanupErrorRetainsBothFailures(t *testing.T) {
	primary := errors.New("primary")
	cleanup := errors.New("cleanup")
	combined := joinCleanupError(primary, cleanup)
	if !errors.Is(combined, primary) || !errors.Is(combined, cleanup) {
		t.Fatalf("combined error does not retain both causes: %v", combined)
	}
}

func TestMasonReceiptVersion(t *testing.T) {
	receipt := masonReceipt{}
	receipt.Source.ID = "pkg:github/example/tool@v1.2.3#asset"
	version, err := masonReceiptVersion(receipt, "receipt.json")
	if err != nil {
		t.Fatal(err)
	}
	if version != "v1.2.3" {
		t.Fatalf("got %q", version)
	}
}

func TestRepositoryDiscoveryDoesNotTrustWorkingDirectory(t *testing.T) {
	t.Setenv("LAZYVIM_REPO", "")
	fake := t.TempDir()
	for name, content := range map[string]string{
		".chezmoiroot":                  "home\n",
		"manifests/tools.env":           "VERSION=\"1\"\n",
		"home/dot_config/nvim/init.lua": "return {}\n",
	} {
		path := filepath.Join(fake, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	original, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(fake); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(original)
	root, actual, err := resolveRepository("", filepath.Join(t.TempDir(), "state"))
	if err != nil {
		t.Fatal(err)
	}
	if root != "" || actual {
		t.Fatalf("trusted ambient working directory %q", root)
	}
}

type failSecondReadFS struct {
	fs.FS
	name  string
	reads int
}

func (f *failSecondReadFS) Open(name string) (fs.File, error) {
	if name == f.name {
		f.reads++
		if f.reads == 2 {
			return nil, errors.New("injected read failure")
		}
	}
	return f.FS.Open(name)
}

func TestEmbeddedSourceFailureCleansTemporaryTree(t *testing.T) {
	broken := &failSecondReadFS{
		FS: fstest.MapFS{
			".chezmoiroot":                  &fstest.MapFile{Data: []byte("home\n")},
			"home/dot_config/nvim/init.lua": &fstest.MapFile{Data: []byte("return {}\n")},
			"manifests/tools.env":           &fstest.MapFile{Data: []byte("VERSION=\"1\"\n")},
		},
		name: "home/dot_config/nvim/init.lua",
	}
	state := t.TempDir()
	if _, err := materializeEmbeddedSourceFrom(broken, state); err == nil {
		t.Fatal("expected injected materialization failure")
	}
	matches, err := filepath.Glob(filepath.Join(state, "embedded-source", "*.tmp-*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 0 {
		t.Fatalf("temporary trees were not cleaned: %v", matches)
	}
}

func TestEmbeddedSourceIsRevalidated(t *testing.T) {
	state := t.TempDir()
	root, err := materializeEmbeddedSource(state)
	if err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(root, "home", "dot_config", "nvim", "init.lua")
	original, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(configPath, []byte("tampered\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	restoredRoot, err := materializeEmbeddedSource(state)
	if err != nil {
		t.Fatal(err)
	}
	if restoredRoot != root {
		t.Fatalf("content address changed: %s != %s", restoredRoot, root)
	}
	restored, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(restored) != string(original) {
		t.Fatal("embedded source tampering was not repaired")
	}
}

func TestInvalidRepositoryEnvironmentFailsClosed(t *testing.T) {
	t.Setenv("LAZYVIM_REPO", filepath.Join(t.TempDir(), "missing"))
	if _, _, err := resolveRepository("", t.TempDir()); err == nil {
		t.Fatal("expected invalid LAZYVIM_REPO to fail")
	}
}

func TestParseBashVersion(t *testing.T) {
	major, minor, err := parseBashVersion("GNU bash, version 5.2.37(1)-release")
	if err != nil {
		t.Fatal(err)
	}
	if major != 5 || minor != 2 {
		t.Fatalf("got %d.%d", major, minor)
	}
}
