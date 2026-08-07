package archive

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"os"
	"path/filepath"
	"testing"

	"github.com/savioserra/lazyvim/internal/config"
	"github.com/ulikunitz/xz"
)

func TestExtractTarGzStripsPrefix(t *testing.T) {
	archivePath := filepath.Join(t.TempDir(), "tool.tar.gz")
	file, err := os.Create(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	compressed := gzip.NewWriter(file)
	writer := tar.NewWriter(compressed)
	content := []byte("binary")
	if err := writer.WriteHeader(&tar.Header{Name: "tool-v1/bin/tool", Mode: 0o755, Size: int64(len(content)), Typeflag: tar.TypeReg}); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write(content); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := compressed.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	destination := t.TempDir()
	if err := Extract(archivePath, destination, config.ArchiveTarGz, "tool-v1", ""); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(destination, "bin", "tool"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(content) {
		t.Fatalf("got %q, want %q", got, content)
	}
}

func TestExtractTarXz(t *testing.T) {
	archivePath := filepath.Join(t.TempDir(), "font.tar.xz")
	file, err := os.Create(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	compressed, err := xz.NewWriter(file)
	if err != nil {
		t.Fatal(err)
	}
	writer := tar.NewWriter(compressed)
	content := []byte("font")
	if err := writer.WriteHeader(&tar.Header{Name: "Font-Regular.ttf", Mode: 0o644, Size: int64(len(content)), Typeflag: tar.TypeReg}); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write(content); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := compressed.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	destination := t.TempDir()
	if err := Extract(archivePath, destination, config.ArchiveTarXz, "", ""); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(filepath.Join(destination, "Font-Regular.ttf")); err != nil || string(got) != string(content) {
		t.Fatalf("got %q, %v", got, err)
	}
}

func TestExtractTarRejectsSymlinks(t *testing.T) {
	archivePath := filepath.Join(t.TempDir(), "links.tar.gz")
	file, err := os.Create(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	compressed := gzip.NewWriter(file)
	writer := tar.NewWriter(compressed)
	if err := writer.WriteHeader(&tar.Header{Name: "pivot", Linkname: ".", Mode: 0o777, Typeflag: tar.TypeSymlink}); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := compressed.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if err := Extract(archivePath, t.TempDir(), config.ArchiveTarGz, "", ""); err == nil {
		t.Fatal("expected archive symlink to fail")
	}
}

func TestExtractZipRejectsTraversal(t *testing.T) {
	archivePath := filepath.Join(t.TempDir(), "bad.zip")
	file, err := os.Create(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	writer := zip.NewWriter(file)
	member, err := writer.Create("../escape")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := member.Write([]byte("bad")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}

	destination := t.TempDir()
	if err := Extract(archivePath, destination, config.ArchiveZip, "", ""); err == nil {
		t.Fatal("expected traversal archive to fail")
	}
	if _, err := os.Stat(filepath.Join(filepath.Dir(destination), "escape")); !os.IsNotExist(err) {
		t.Fatalf("archive escaped destination: %v", err)
	}
}
