package download

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"sync"
	"testing"
	"testing/fstest"
)

func digest(content []byte) string {
	hash := sha256.Sum256(content)
	return hex.EncodeToString(hash[:])
}

func TestFetchRetriesAndVerifies(t *testing.T) {
	content := []byte("verified payload")
	attempts := 0
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		attempts++
		if attempts == 1 {
			http.Error(response, "retry", http.StatusServiceUnavailable)
			return
		}
		_, _ = response.Write(content)
	}))
	defer server.Close()

	downloader := New(nil, nil)
	downloader.RetryDelay = 0
	path, err := downloader.Fetch(context.Background(), Artifact{URL: server.URL, SHA256: digest(content), FileName: "tool.zip"}, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(content) || attempts != 2 {
		t.Fatalf("got payload %q after %d attempts", got, attempts)
	}
}

func TestFetchUsesEmbeddedBundle(t *testing.T) {
	content := []byte("offline")
	embedded := fstest.MapFS{"bundles/tool.tar.gz": &fstest.MapFile{Data: content, Mode: fs.FileMode(0o644)}}
	downloader := New(embedded, nil)
	path, err := downloader.Fetch(context.Background(), Artifact{URL: "https://invalid.example/tool", SHA256: digest(content), FileName: "tool.tar.gz"}, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(content) {
		t.Fatalf("got %q, want %q", got, content)
	}
}

func TestConcurrentFetchesPublishOneVerifiedArchive(t *testing.T) {
	content := []byte("concurrent payload")
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		_, _ = response.Write(content)
	}))
	defer server.Close()
	directory := t.TempDir()
	downloader := New(nil, nil)
	artifact := Artifact{URL: server.URL, SHA256: digest(content), FileName: "tool.zip"}
	var wait sync.WaitGroup
	errors := make(chan error, 8)
	for range 8 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			_, err := downloader.Fetch(context.Background(), artifact, directory)
			errors <- err
		}()
	}
	wait.Wait()
	close(errors)
	for err := range errors {
		if err != nil {
			t.Fatal(err)
		}
	}
	matches, err := ChecksumMatches(directory+string(os.PathSeparator)+artifact.FileName, artifact.SHA256)
	if err != nil || !matches {
		t.Fatalf("published archive is invalid: %v", err)
	}
}

func TestOfflineFetchDoesNotUseNetwork(t *testing.T) {
	requests := 0
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		requests++
		_, _ = response.Write([]byte("network"))
	}))
	defer server.Close()
	downloader := New(nil, nil)
	downloader.Offline = true
	_, err := downloader.Fetch(context.Background(), Artifact{URL: server.URL, SHA256: digest([]byte("network")), FileName: "tool.zip"}, t.TempDir())
	if err == nil {
		t.Fatal("expected offline cache miss to fail")
	}
	if requests != 0 {
		t.Fatalf("offline mode made %d network request(s)", requests)
	}
}

func TestFetchRejectsChecksumMismatch(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, _ *http.Request) {
		_, _ = response.Write([]byte("wrong"))
	}))
	defer server.Close()
	downloader := New(nil, nil)
	downloader.Attempts = 1
	_, err := downloader.Fetch(context.Background(), Artifact{URL: server.URL, SHA256: digest([]byte("expected")), FileName: "tool.zip"}, t.TempDir())
	if err == nil {
		t.Fatal("expected checksum mismatch")
	}
}
