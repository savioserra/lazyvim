package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
)

type RestoreOptions struct {
	PluginsOnly bool
	MasonOnly   bool
	SkipParsers bool
}

type masonReceipt struct {
	Name   string `json:"name"`
	Source struct {
		ID string `json:"id"`
	} `json:"source"`
}

var masonVersionPattern = regexp.MustCompile(`@([^@#]+)(?:#.*)?$`)

func (a *App) Restore(ctx context.Context, options RestoreOptions) error {
	if options.PluginsOnly && options.MasonOnly {
		return fmt.Errorf("--plugins-only and --mason-only are mutually exclusive")
	}
	if err := a.Apply(ctx, nil); err != nil {
		return err
	}
	nvim, err := a.nvimPath()
	if err != nil {
		return err
	}
	if _, err := a.output(ctx, nvim, "--version"); err != nil {
		return fmt.Errorf("pinned Neovim is not usable: %w", err)
	}

	restorePlugins := !options.MasonOnly
	restoreTmux := restorePlugins && runtime.GOOS != "windows"
	restoreMason := !options.PluginsOnly
	restoreParsers := !options.PluginsOnly && !options.MasonOnly && !options.SkipParsers

	if restorePlugins {
		if err := a.restorePlugins(ctx, nvim); err != nil {
			return err
		}
	}
	if restoreTmux {
		if err := a.RestoreTmux(ctx); err != nil {
			return err
		}
	}
	if restoreMason {
		if err := a.restoreMason(ctx, nvim); err != nil {
			return err
		}
	}
	if restoreParsers {
		a.logf("Installing missing Tree-sitter parsers")
		if err := a.run(ctx, nvim, "--headless", "+Lazy load nvim-treesitter", "+lua require('dotfiles.restore').parsers()", "+qa"); err != nil {
			return err
		}
	}
	a.logf("Restore complete")
	return nil
}

func (a *App) restorePlugins(ctx context.Context, nvim string) (returnErr error) {
	a.logf("Installing missing plugins before enforcing lazy-lock.json")
	committed := filepath.Join(a.repoRoot, "home", "dot_config", "nvim", "lazy-lock.json")
	active := filepath.Join(a.paths.Home, ".config", "nvim", "lazy-lock.json")
	snapshot, err := os.CreateTemp("", "dotfiles-lazy-lock-*.json")
	if err != nil {
		return err
	}
	snapshotPath := snapshot.Name()
	if err := snapshot.Close(); err != nil {
		return err
	}
	defer os.Remove(snapshotPath)
	if err := a.copyFile(committed, snapshotPath, 0o600); err != nil {
		return err
	}
	defer func() {
		if err := a.copyFile(snapshotPath, active, 0o644); err != nil {
			returnErr = joinCleanupError(returnErr, fmt.Errorf("restore lazy-lock.json during cleanup: %w", err))
		}
	}()

	if err := a.run(ctx, nvim, "--headless", "+Lazy! install", "+qa"); err != nil {
		return err
	}
	if err := a.copyFile(snapshotPath, active, 0o644); err != nil {
		return err
	}
	a.logf("Restoring plugins from lazy-lock.json")
	if err := a.run(ctx, nvim, "--headless", "+Lazy! restore", "+qa"); err != nil {
		return err
	}
	if err := a.copyFile(snapshotPath, active, 0o644); err != nil {
		return err
	}
	if err := a.run(ctx, nvim, "--headless", "+lua require('dotfiles.restore').plugins()", "+qa"); err != nil {
		return err
	}
	return nil
}

func (a *App) restoreMason(ctx context.Context, nvim string) error {
	lock, err := readMasonLock(filepath.Join(a.repoRoot, "home", "dot_config", "nvim", "mason-lock.json"))
	if err != nil {
		return err
	}
	packagesHome := filepath.Join(a.paths.NvimData, "mason", "packages")
	var specs []string
	for _, name := range sortedKeys(lock) {
		expected := lock[name]
		actual := ""
		receiptPath := filepath.Join(packagesHome, name, "mason-receipt.json")
		if regularFile(receiptPath) {
			receipt, receiptErr := readMasonReceipt(receiptPath)
			if receiptErr == nil {
				actual, receiptErr = masonReceiptVersion(receipt, receiptPath)
			}
			if receiptErr != nil {
				a.warnf("ignoring invalid Mason receipt for %s: %v", name, receiptErr)
				actual = ""
			}
		}
		if actual != expected {
			specs = append(specs, name+"@"+expected)
		}
	}
	if len(specs) == 0 {
		a.logf("Mason packages already match mason-lock.json")
		return nil
	}
	a.logf("Restoring %d Mason package(s) from mason-lock.json", len(specs))
	return a.run(ctx, nvim, "--headless", "+Lazy load mason.nvim", "+MasonInstall --force --strict "+strings.Join(specs, " "), "+qa")
}

func joinCleanupError(primary, cleanup error) error {
	return errors.Join(primary, cleanup)
}

func readMasonLock(path string) (map[string]string, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read Mason lockfile: %w", err)
	}
	lock := map[string]string{}
	if err := json.Unmarshal(content, &lock); err != nil {
		return nil, fmt.Errorf("parse Mason lockfile: %w", err)
	}
	return lock, nil
}

func readMasonReceipt(path string) (masonReceipt, error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return masonReceipt{}, err
	}
	var receipt masonReceipt
	if err := json.Unmarshal(content, &receipt); err != nil {
		return masonReceipt{}, fmt.Errorf("parse Mason receipt %s: %w", path, err)
	}
	return receipt, nil
}

func masonReceiptVersion(receipt masonReceipt, path string) (string, error) {
	matches := masonVersionPattern.FindStringSubmatch(receipt.Source.ID)
	if len(matches) != 2 {
		return "", fmt.Errorf("could not determine version from Mason receipt: %s", path)
	}
	return matches[1], nil
}

func sortedKeys(values map[string]string) []string {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}
