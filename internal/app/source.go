package app

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"

	lazyvim "github.com/savioserra/lazyvim"
)

func resolveRepository(explicit, stateHome string) (string, bool, error) {
	if explicit != "" {
		root, err := validateRepository(explicit)
		return root, err == nil, err
	}
	if environment := strings.TrimSpace(os.Getenv("LAZYVIM_REPO")); environment != "" {
		root, err := validateRepository(environment)
		if err != nil {
			return "", false, fmt.Errorf("invalid LAZYVIM_REPO: %w", err)
		}
		return root, true, nil
	}
	var candidates []string
	if content, err := os.ReadFile(filepath.Join(stateHome, "repository")); err == nil {
		candidates = append(candidates, strings.TrimSpace(string(content)))
	}
	if executable, err := os.Executable(); err == nil {
		candidates = append(candidates, filepath.Dir(executable))
	}
	seen := map[string]bool{}
	for _, candidate := range candidates {
		if candidate == "" {
			continue
		}
		for directory := candidate; ; directory = filepath.Dir(directory) {
			clean := filepath.Clean(directory)
			if !seen[clean] {
				seen[clean] = true
				if root, err := validateRepository(clean); err == nil {
					return root, true, nil
				}
			}
			parent := filepath.Dir(directory)
			if parent == directory {
				break
			}
		}
	}
	return "", false, nil
}

func validateRepository(root string) (string, error) {
	absolute, err := filepath.Abs(root)
	if err != nil {
		return "", err
	}
	for _, required := range []string{".chezmoiroot", filepath.Join("manifests", "tools.env"), filepath.Join("home", "dot_config", "nvim", "init.lua")} {
		if _, err := os.Stat(filepath.Join(absolute, required)); err != nil {
			return "", fmt.Errorf("%s is not a LazyVim repository: missing %s", absolute, required)
		}
	}
	return absolute, nil
}

func openManifest(embedded fs.FS, repository string, actual bool) (io.ReadCloser, error) {
	if actual {
		file, err := os.Open(filepath.Join(repository, "manifests", "tools.env"))
		if err != nil {
			return nil, fmt.Errorf("open tool manifest: %w", err)
		}
		return file, nil
	}
	file, err := embedded.Open("manifests/tools.env")
	if err != nil {
		return nil, fmt.Errorf("open embedded tool manifest: %w", err)
	}
	return file, nil
}

func materializeEmbeddedSource(stateHome string) (string, error) {
	return materializeEmbeddedSourceFrom(lazyvim.Embedded, stateHome)
}

func materializeEmbeddedSourceFrom(embedded fs.FS, stateHome string) (string, error) {
	hash := sha256.New()
	var names []string
	err := fs.WalkDir(embedded, ".", func(name string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() || !(name == ".chezmoiroot" || strings.HasPrefix(name, "home/") || strings.HasPrefix(name, "manifests/")) {
			return nil
		}
		names = append(names, name)
		return nil
	})
	if err != nil {
		return "", fmt.Errorf("enumerate embedded source: %w", err)
	}
	sort.Strings(names)
	for _, name := range names {
		content, err := fs.ReadFile(embedded, name)
		if err != nil {
			return "", fmt.Errorf("hash embedded source %s: %w", name, err)
		}
		_, _ = io.WriteString(hash, name)
		_, _ = hash.Write(content)
	}
	identity := hex.EncodeToString(hash.Sum(nil))[:16]
	root := filepath.Join(stateHome, "embedded-source", identity)
	if embeddedSourceMatches(embedded, root, names, identity) {
		return root, nil
	}
	_ = os.RemoveAll(root)
	temporary := root + fmt.Sprintf(".tmp-%d", os.Getpid())
	_ = os.RemoveAll(temporary)
	defer os.RemoveAll(temporary)
	for _, name := range names {
		content, err := fs.ReadFile(embedded, name)
		if err != nil {
			return "", fmt.Errorf("read embedded source %s: %w", name, err)
		}
		target := filepath.Join(temporary, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return "", fmt.Errorf("create embedded source directory for %s: %w", name, err)
		}
		if err := os.WriteFile(target, content, 0o644); err != nil {
			return "", fmt.Errorf("write embedded source %s: %w", name, err)
		}
	}
	if err := os.WriteFile(filepath.Join(temporary, ".complete"), []byte(identity+"\n"), 0o644); err != nil {
		return "", fmt.Errorf("write embedded source marker: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(root), 0o755); err != nil {
		return "", fmt.Errorf("create embedded source root: %w", err)
	}
	if err := os.Rename(temporary, root); err != nil {
		if embeddedSourceMatches(embedded, root, names, identity) {
			return root, nil
		}
		return "", fmt.Errorf("publish embedded source: %w", err)
	}
	return root, nil
}

func embeddedSourceMatches(embedded fs.FS, root string, names []string, identity string) bool {
	marker, err := os.ReadFile(filepath.Join(root, ".complete"))
	if err != nil || strings.TrimSpace(string(marker)) != identity {
		return false
	}
	for _, name := range names {
		expected, err := fs.ReadFile(embedded, name)
		if err != nil {
			return false
		}
		actual, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(name)))
		if err != nil || !bytes.Equal(actual, expected) {
			return false
		}
	}
	return true
}

func (a *App) requireActualRepository(operation string) error {
	if !a.actualRepo {
		return fmt.Errorf("%s requires a repository checkout; run inside the clone or set --repo", operation)
	}
	return nil
}

func (a *App) rememberRepository() error {
	if !a.actualRepo {
		return nil
	}
	if err := os.MkdirAll(a.paths.State, 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(a.paths.State, "repository"), []byte(a.repoRoot+"\n"), 0o600)
}
