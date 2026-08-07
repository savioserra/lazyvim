package download

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"github.com/savioserra/lazyvim/internal/atomicfile"
)

type Artifact struct {
	URL      string
	SHA256   string
	FileName string
}

const maxArtifactSize int64 = 1 << 30 // 1 GiB

type Logger func(format string, args ...any)

type Downloader struct {
	Client     *http.Client
	Embedded   fs.FS
	Attempts   int
	RetryDelay time.Duration
	Offline    bool
	Log        Logger
}

func New(embedded fs.FS, log Logger) *Downloader {
	return &Downloader{
		Client: &http.Client{
			Timeout: 30 * time.Minute,
			CheckRedirect: func(request *http.Request, _ []*http.Request) error {
				if request.URL.Scheme != "https" {
					return fmt.Errorf("refusing redirect to non-HTTPS URL %s", request.URL)
				}
				return nil
			},
		},
		Embedded:   embedded,
		Attempts:   5,
		RetryDelay: 2 * time.Second,
		Log:        log,
	}
}

func (d *Downloader) SetOffline(offline bool) {
	d.Offline = offline
}

func (d *Downloader) Fetch(ctx context.Context, artifact Artifact, directory string) (string, error) {
	if err := validateArtifact(artifact); err != nil {
		return "", err
	}
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return "", fmt.Errorf("create download directory: %w", err)
	}
	destination := filepath.Join(directory, artifact.FileName)
	if matches, err := ChecksumMatches(destination, artifact.SHA256); err != nil {
		return "", err
	} else if matches {
		d.log("Using cached %s", artifact.FileName)
		return destination, nil
	}
	if d.Embedded != nil {
		if source, err := d.Embedded.Open(path.Join("bundles", artifact.FileName)); err == nil {
			d.log("Using bundled %s", artifact.FileName)
			writeErr := writeVerified(source, destination, artifact.SHA256)
			closeErr := source.Close()
			if writeErr != nil {
				return "", fmt.Errorf("extract bundled download %s: %w", artifact.FileName, writeErr)
			}
			if closeErr != nil {
				return "", fmt.Errorf("close bundled download %s: %w", artifact.FileName, closeErr)
			}
			return destination, nil
		} else if !errors.Is(err, fs.ErrNotExist) {
			return "", fmt.Errorf("open bundled download %s: %w", artifact.FileName, err)
		}
	}
	if d.Offline {
		return "", fmt.Errorf("%s is not cached or bundled and offline mode is enabled", artifact.FileName)
	}

	d.log("Downloading %s", artifact.FileName)
	attempts := d.Attempts
	if attempts < 1 {
		attempts = 1
	}
	var lastErr error
	for attempt := 1; attempt <= attempts; attempt++ {
		lastErr = d.downloadOnce(ctx, artifact, destination)
		if lastErr == nil {
			return destination, nil
		}
		if attempt == attempts || !retryable(lastErr) {
			break
		}
		timer := time.NewTimer(d.RetryDelay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return "", ctx.Err()
		case <-timer.C:
		}
	}
	return "", fmt.Errorf("download %s: %w", artifact.FileName, lastErr)
}

func (d *Downloader) downloadOnce(ctx context.Context, artifact Artifact, destination string) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, artifact.URL, nil)
	if err != nil {
		return err
	}
	request.Header.Set("User-Agent", "dotfiles-cli/1")
	response, err := d.Client.Do(request)
	if err != nil {
		return retryError{err: err}
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		err := fmt.Errorf("server returned %s", response.Status)
		if response.StatusCode == http.StatusTooManyRequests || response.StatusCode >= 500 {
			return retryError{err: err}
		}
		return err
	}
	if response.ContentLength > maxArtifactSize {
		return fmt.Errorf("archive exceeds the %d-byte size limit", maxArtifactSize)
	}
	return writeVerified(response.Body, destination, artifact.SHA256)
}

func writeVerified(source io.Reader, destination, expected string) error {
	file, err := os.CreateTemp(filepath.Dir(destination), "."+filepath.Base(destination)+".part-*")
	if err != nil {
		return err
	}
	partial := file.Name()
	defer os.Remove(partial)
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return err
	}
	hash := sha256.New()
	written, copyErr := io.Copy(io.MultiWriter(file, hash), io.LimitReader(source, maxArtifactSize+1))
	var syncErr error
	if copyErr == nil && written <= maxArtifactSize {
		syncErr = file.Sync()
	}
	closeErr := file.Close()
	if written > maxArtifactSize {
		return fmt.Errorf("archive exceeds the %d-byte size limit", maxArtifactSize)
	}
	if copyErr != nil {
		return retryError{err: copyErr}
	}
	if syncErr != nil {
		return syncErr
	}
	if closeErr != nil {
		_ = os.Remove(partial)
		return closeErr
	}
	actual := hex.EncodeToString(hash.Sum(nil))
	if !strings.EqualFold(actual, expected) {
		_ = os.Remove(partial)
		return fmt.Errorf("checksum mismatch: expected %s, got %s", strings.ToLower(expected), actual)
	}
	if err := os.Chmod(partial, 0o644); err != nil {
		_ = os.Remove(partial)
		return err
	}
	if err := atomicfile.Replace(partial, destination); err != nil {
		if matches, checkErr := ChecksumMatches(destination, expected); checkErr == nil && matches {
			return nil
		}
		return err
	}
	return nil
}

func ChecksumMatches(filePath, expected string) (bool, error) {
	file, err := os.Open(filePath)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("open %s: %w", filePath, err)
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return false, fmt.Errorf("hash %s: %w", filePath, err)
	}
	return strings.EqualFold(hex.EncodeToString(hash.Sum(nil)), expected), nil
}

func validateArtifact(artifact Artifact) error {
	if artifact.URL == "" || artifact.SHA256 == "" || artifact.FileName == "" {
		return errors.New("download artifact is incomplete")
	}
	if filepath.Base(artifact.FileName) != artifact.FileName || strings.ContainsAny(artifact.FileName, `/\\`) {
		return fmt.Errorf("unsafe download filename: %q", artifact.FileName)
	}
	decoded, err := hex.DecodeString(artifact.SHA256)
	if err != nil || len(decoded) != sha256.Size {
		return fmt.Errorf("invalid SHA-256 for %s", artifact.FileName)
	}
	return nil
}

type retryError struct{ err error }

func (e retryError) Error() string { return e.err.Error() }
func (e retryError) Unwrap() error { return e.err }

func retryable(err error) bool {
	var retry retryError
	return errors.As(err, &retry)
}

func (d *Downloader) log(format string, args ...any) {
	if d.Log != nil {
		d.Log(format, args...)
	}
}
