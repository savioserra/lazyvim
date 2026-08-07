package archive

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"

	"github.com/savioserra/lazyvim/internal/config"
	"github.com/ulikunitz/xz"
)

func Extract(archivePath, destination string, kind config.ArchiveKind, stripPrefix, destinationPrefix string) error {
	if err := os.MkdirAll(destination, 0o755); err != nil {
		return fmt.Errorf("create extraction directory: %w", err)
	}
	switch kind {
	case config.ArchiveZip:
		return extractZip(archivePath, destination, stripPrefix, destinationPrefix)
	case config.ArchiveTarGz, config.ArchiveTarXz:
		return extractTar(archivePath, destination, kind, stripPrefix, destinationPrefix)
	default:
		return fmt.Errorf("unsupported archive type: %s", kind)
	}
}

const (
	maxArchiveEntries  = 100_000
	maxArchiveFileSize = int64(2 << 30)
	maxExtractedSize   = int64(4 << 30)
	maxArchivePath     = 4096
)

func extractTar(archivePath, destination string, kind config.ArchiveKind, stripPrefix, destinationPrefix string) error {
	file, err := os.Open(archivePath)
	if err != nil {
		return fmt.Errorf("open archive: %w", err)
	}
	defer file.Close()

	var reader io.Reader = file
	switch kind {
	case config.ArchiveTarGz:
		compressed, err := gzip.NewReader(file)
		if err != nil {
			return fmt.Errorf("open gzip stream: %w", err)
		}
		defer compressed.Close()
		reader = compressed
	case config.ArchiveTarXz:
		compressed, err := xz.NewReader(file)
		if err != nil {
			return fmt.Errorf("open xz stream: %w", err)
		}
		reader = compressed
	}

	found := false
	entries := 0
	var extractedSize int64
	tarReader := tar.NewReader(reader)
	for {
		header, err := tarReader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fmt.Errorf("read tar archive: %w", err)
		}
		entries++
		if entries > maxArchiveEntries {
			return fmt.Errorf("archive contains more than %d entries", maxArchiveEntries)
		}
		if len(header.Name) > maxArchivePath {
			return fmt.Errorf("archive path is too long")
		}
		relative, include, err := archiveRelative(header.Name, stripPrefix, destinationPrefix)
		if err != nil {
			return err
		}
		if !include {
			continue
		}
		found = true
		if len(relative) > maxArchivePath {
			return fmt.Errorf("archive path is too long: %q", relative[:64])
		}
		if header.Size < 0 || header.Size > maxArchiveFileSize || extractedSize > maxExtractedSize-header.Size {
			return fmt.Errorf("archive exceeds extraction size limits at %q", relative)
		}
		if header.Typeflag == tar.TypeReg || header.Typeflag == tar.TypeRegA {
			extractedSize += header.Size
		}
		target, err := safeTarget(destination, relative)
		if err != nil {
			return err
		}
		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, normalizedMode(header.FileInfo().Mode(), true)); err != nil {
				return fmt.Errorf("create archive directory %s: %w", relative, err)
			}
		case tar.TypeReg, tar.TypeRegA:
			if err := writeFile(target, tarReader, normalizedMode(header.FileInfo().Mode(), false)); err != nil {
				return fmt.Errorf("extract %s: %w", relative, err)
			}
		case tar.TypeSymlink, tar.TypeLink:
			return fmt.Errorf("archive links are not supported: %q", header.Name)
		case tar.TypeXGlobalHeader, tar.TypeXHeader:
			continue
		default:
			return fmt.Errorf("archive contains unsupported entry %q (type %d)", header.Name, header.Typeflag)
		}
	}
	if !found {
		return fmt.Errorf("archive did not contain files under expected prefix %q", stripPrefix)
	}
	return nil
}

func extractZip(archivePath, destination, stripPrefix, destinationPrefix string) error {
	reader, err := zip.OpenReader(archivePath)
	if err != nil {
		return fmt.Errorf("open zip archive: %w", err)
	}
	defer reader.Close()

	if len(reader.File) > maxArchiveEntries {
		return fmt.Errorf("archive contains more than %d entries", maxArchiveEntries)
	}
	found := false
	var extractedSize uint64
	for _, file := range reader.File {
		if len(file.Name) > maxArchivePath {
			return fmt.Errorf("archive path is too long")
		}
		relative, include, err := archiveRelative(file.Name, stripPrefix, destinationPrefix)
		if err != nil {
			return err
		}
		if !include {
			continue
		}
		found = true
		if len(relative) > maxArchivePath {
			return fmt.Errorf("archive path is too long: %q", relative[:64])
		}
		if file.UncompressedSize64 > uint64(maxArchiveFileSize) || extractedSize > uint64(maxExtractedSize)-file.UncompressedSize64 {
			return fmt.Errorf("archive exceeds extraction size limits at %q", relative)
		}
		if !file.FileInfo().IsDir() {
			extractedSize += file.UncompressedSize64
		}
		target, err := safeTarget(destination, relative)
		if err != nil {
			return err
		}
		if file.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return fmt.Errorf("create archive directory %s: %w", relative, err)
			}
			continue
		}
		source, err := file.Open()
		if err != nil {
			return fmt.Errorf("open zip member %s: %w", relative, err)
		}
		if file.Mode()&os.ModeSymlink != 0 {
			_ = source.Close()
			return fmt.Errorf("archive links are not supported: %q", file.Name)
		}
		mode := normalizedMode(file.Mode(), false)
		err = writeFile(target, source, mode)
		closeErr := source.Close()
		if err != nil {
			return fmt.Errorf("extract %s: %w", relative, err)
		}
		if closeErr != nil {
			return fmt.Errorf("close zip member %s: %w", relative, closeErr)
		}
	}
	if !found {
		return fmt.Errorf("archive did not contain files under expected prefix %q", stripPrefix)
	}
	return nil
}

func archiveRelative(name, stripPrefix, destinationPrefix string) (string, bool, error) {
	name = strings.ReplaceAll(name, "\\", "/")
	clean := path.Clean(name)
	if clean == "." {
		return "", false, nil
	}
	if path.IsAbs(clean) || clean == ".." || strings.HasPrefix(clean, "../") || strings.Contains(clean, ":") {
		return "", false, fmt.Errorf("archive contains unsafe path %q", name)
	}
	if stripPrefix != "" {
		prefix := strings.TrimSuffix(path.Clean(strings.ReplaceAll(stripPrefix, "\\", "/")), "/")
		if clean == prefix {
			return "", false, nil
		}
		if !strings.HasPrefix(clean, prefix+"/") {
			return "", false, nil
		}
		clean = strings.TrimPrefix(clean, prefix+"/")
	}
	if destinationPrefix != "" {
		clean = path.Join(destinationPrefix, clean)
	}
	if clean == "." || clean == "" {
		return "", false, nil
	}
	return clean, true, nil
}

func safeTarget(root, relative string) (string, error) {
	root = filepath.Clean(root)
	target := filepath.Join(root, filepath.FromSlash(relative))
	resolved, err := filepath.Rel(root, target)
	if err != nil || resolved == ".." || strings.HasPrefix(resolved, ".."+string(filepath.Separator)) || filepath.IsAbs(resolved) {
		return "", fmt.Errorf("archive path escapes destination: %q", relative)
	}
	return target, nil
}

func writeFile(target string, source io.Reader, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	if info, err := os.Lstat(target); err == nil && info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("refusing to overwrite symlink %s", target)
	} else if err != nil && !os.IsNotExist(err) {
		return err
	}
	file, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(file, source)
	closeErr := file.Close()
	if copyErr != nil {
		return copyErr
	}
	return closeErr
}

func normalizedMode(mode os.FileMode, directory bool) os.FileMode {
	permissions := mode.Perm()
	if permissions == 0 {
		if directory {
			return 0o755
		}
		return 0o644
	}
	return permissions
}
