package app

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/savioserra/lazyvim/internal/buildinfo"
)

func (a *App) Update(ctx context.Context) error {
	if err := a.requireActualRepository("update"); err != nil {
		return err
	}
	if err := a.requireGitClean(ctx, "updating"); err != nil {
		return err
	}
	if err := a.requireChezmoiClean(ctx, "updating"); err != nil {
		return err
	}
	nvim, err := a.nvimPath()
	if err != nil {
		return err
	}
	a.logf("Updating plugins and lazy-lock.json")
	if err := a.run(ctx, nvim, "--headless", "+Lazy! sync", "+qa"); err != nil {
		return err
	}
	lock, err := readMasonLock(filepath.Join(a.repoRoot, "home", "dot_config", "nvim", "mason-lock.json"))
	if err != nil {
		return err
	}
	packages := sortedKeys(lock)
	if len(packages) > 0 {
		a.logf("Updating %d Mason packages", len(packages))
		if err := a.run(ctx, nvim, "--headless", "+Lazy load mason.nvim", "+MasonInstall --force --strict "+strings.Join(packages, " "), "+qa"); err != nil {
			return err
		}
		if err := a.LockMason(ctx); err != nil {
			return err
		}
	}
	a.logf("Updating installed Tree-sitter parsers")
	if err := a.run(ctx, nvim, "--headless", "+Lazy load nvim-treesitter", "+lua assert(require('nvim-treesitter').update(nil, { summary = true }):wait())", "+qa"); err != nil {
		return err
	}
	if err := a.Capture(ctx, []string{filepath.Join(a.paths.Home, ".config", "nvim")}); err != nil {
		return err
	}
	if err := a.Check(ctx); err != nil {
		return err
	}
	a.logf("Update complete; review and commit the lockfile changes")
	return nil
}

func (a *App) Sync(ctx context.Context) error {
	if err := a.requireActualRepository("sync"); err != nil {
		return err
	}
	if err := a.requireChezmoiClean(ctx, "syncing"); err != nil {
		return err
	}
	if err := a.requireGitClean(ctx, "syncing"); err != nil {
		return err
	}
	if _, err := a.output(ctx, "git", "-C", a.repoRoot, "rev-parse", "--abbrev-ref", "@{upstream}"); err == nil {
		a.logf("Pulling configuration changes")
		if err := a.run(ctx, "git", "-C", a.repoRoot, "pull", "--ff-only"); err != nil {
			return err
		}
	} else {
		a.warnf("no upstream branch is configured; skipping git pull")
	}
	if err := os.MkdirAll(a.paths.State, 0o755); err != nil {
		return err
	}
	temporary, err := os.MkdirTemp(a.paths.State, "sync-build-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temporary)
	binary := filepath.Join(temporary, "lazyvim"+runtimeExecutableExtension())
	version, err := a.output(ctx, "git", "-C", a.repoRoot, "describe", "--always", "--dirty")
	if err != nil {
		return fmt.Errorf("determine updated CLI version: %w", err)
	}
	a.logf("Building the updated lazyvim CLI")
	if err := a.runIn(ctx, a.repoRoot, "go", syncBuildArguments(version, binary)...); err != nil {
		return fmt.Errorf("build updated lazyvim CLI: %w", err)
	}
	return a.run(ctx, binary, "--repo", a.repoRoot, "sync-continue")
}

func syncBuildArguments(version, binary string) []string {
	ldflags := "-s -w -X " + buildinfo.Variable() + "=" + version
	return []string{"build", "-trimpath", "-ldflags", ldflags, "-o", binary, "./cmd/lazyvim"}
}

func (a *App) SyncContinue(ctx context.Context) error {
	if err := a.Install(ctx, InstallOptions{NoRestore: true}); err != nil {
		return err
	}
	if err := a.Restore(ctx, RestoreOptions{}); err != nil {
		return err
	}
	if err := a.Check(ctx); err != nil {
		return err
	}
	a.logf("Sync complete")
	return nil
}

func (a *App) requireGitClean(ctx context.Context, operation string) error {
	status, err := a.output(ctx, "git", "-C", a.repoRoot, "status", "--porcelain")
	if err != nil {
		return err
	}
	if status != "" {
		return fmt.Errorf("commit or stash repository changes before %s", operation)
	}
	return nil
}

func (a *App) GitStatus(ctx context.Context) ([]string, error) {
	status, err := a.output(ctx, "git", "-C", a.repoRoot, "status", "--porcelain")
	if err != nil {
		return nil, err
	}
	if status == "" {
		return nil, nil
	}
	lines := strings.Split(status, "\n")
	sort.Strings(lines)
	return lines, nil
}
