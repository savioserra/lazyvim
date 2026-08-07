package app

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"

	"github.com/savioserra/lazyvim/internal/config"
)

func TestDownloadCommandsUseInjectedDownloader(t *testing.T) {
	manifest, err := os.Open(filepath.Join("..", "..", "manifests", "tools.env"))
	if err != nil {
		t.Fatal(err)
	}
	tools, err := config.Parse(manifest)
	_ = manifest.Close()
	if err != nil {
		t.Fatal(err)
	}
	platform, err := config.CurrentPlatform()
	if err != nil {
		t.Fatal(err)
	}
	catalog, err := config.NewCatalog(tools, platform)
	if err != nil {
		t.Fatal(err)
	}
	downloader := &fakeDownloader{path: filepath.Join(t.TempDir(), "unused")}
	var output bytes.Buffer
	cache := filepath.Join(t.TempDir(), "downloads")
	application := &App{
		platform: platform, tools: tools, catalog: catalog, downloader: downloader,
		embedded: fstest.MapFS{"bundles/" + catalog.Releases[0].ArchiveName: &fstest.MapFile{Data: []byte("archive")}},
		paths:    Paths{DownloadCache: cache}, out: &output, err: &output,
	}
	if err := application.FetchDownloads(context.Background(), DownloadOptions{Names: []string{"nvim"}}); err != nil {
		t.Fatal(err)
	}
	if len(downloader.fetched) != 1 || downloader.fetched[0].FileName != catalog.Releases[0].ArchiveName {
		t.Fatalf("unexpected downloads: %+v", downloader.fetched)
	}
	output.Reset()
	if err := application.ListDownloads(false, true); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), catalog.Releases[0].ArchiveName) || !strings.Contains(output.String(), "bundled") {
		t.Fatalf("download list did not use injected bundles: %s", output.String())
	}
	if err := os.MkdirAll(cache, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cache, "stale"), []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := application.CleanDownloads(); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(cache)
	if err != nil || len(entries) != 0 {
		t.Fatalf("download cache was not cleaned: %v, %v", entries, err)
	}
}
