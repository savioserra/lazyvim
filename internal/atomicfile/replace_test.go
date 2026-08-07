package atomicfile

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestWritePublishesOverExistingFile(t *testing.T) {
	destination := filepath.Join(t.TempDir(), "destination")
	if err := os.WriteFile(destination, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := Write(destination, []byte("new"), 0o640); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "new" {
		t.Fatalf("got %q, want new", content)
	}
}

func TestWritePreservesDestinationWhenPublicationFails(t *testing.T) {
	directory := t.TempDir()
	destination := filepath.Join(directory, "destination")
	if err := os.WriteFile(destination, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	failure := errors.New("publication failed")
	err := write(destination, []byte("new"), 0o600, func(source, target string) error {
		if filepath.Dir(source) != directory || target != destination {
			t.Fatalf("unexpected publication paths: %s -> %s", source, target)
		}
		return failure
	})
	if !errors.Is(err, failure) {
		t.Fatalf("got %v, want publication failure", err)
	}
	content, readErr := os.ReadFile(destination)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if string(content) != "old" {
		t.Fatalf("destination changed to %q", content)
	}
	entries, readDirErr := os.ReadDir(directory)
	if readDirErr != nil {
		t.Fatal(readDirErr)
	}
	if len(entries) != 1 || entries[0].Name() != "destination" {
		t.Fatalf("staged file was not cleaned up: %+v", entries)
	}
}

func TestReplacePublishesOverExistingFile(t *testing.T) {
	directory := t.TempDir()
	source := filepath.Join(directory, "source")
	destination := filepath.Join(directory, "destination")
	if err := os.WriteFile(source, []byte("new"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(destination, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := Replace(source, destination); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(destination)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "new" {
		t.Fatalf("got %q, want new", content)
	}
	if _, err := os.Stat(source); !os.IsNotExist(err) {
		t.Fatalf("source still exists: %v", err)
	}
}
