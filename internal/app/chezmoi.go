package app

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
)

func (a *App) migrateAndApply(ctx context.Context) error {
	marker := filepath.Join(a.paths.State, "chezmoi-source-state-v1")
	managedNvim := filepath.Join(a.paths.Home, ".config", "nvim")
	firstApply := !regularFile(marker)
	if firstApply {
		targets := []string{managedNvim}
		if runtime.GOOS != "windows" {
			targets = append(targets, filepath.Join(a.paths.Home, ".tmux.conf"))
		}
		for _, target := range targets {
			if pathExists(target) {
				if err := a.backup(target); err != nil {
					return err
				}
			}
		}
	}
	applyArguments := []string(nil)
	if firstApply {
		// Existing targets were preserved above, so non-interactive replacement is safe.
		applyArguments = []string{"--force"}
	}
	if err := a.Apply(ctx, applyArguments); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(marker), 0o755); err != nil {
		return err
	}
	return os.WriteFile(marker, []byte("applied\n"), 0o644)
}

func (a *App) Apply(ctx context.Context, arguments []string) error {
	chezmoi, err := a.chezmoiPath()
	if err != nil {
		return err
	}
	a.logf("Applying managed configuration with chezmoi")
	commandArguments := []string{"--source", a.repoRoot, "--destination", a.paths.Home, "apply"}
	commandArguments = append(commandArguments, arguments...)
	if err := a.run(ctx, chezmoi, commandArguments...); err != nil {
		return err
	}
	managedNvim := filepath.Join(a.paths.Home, ".config", "nvim")
	if runtime.GOOS == "windows" {
		if err := a.connectDirectory(managedNvim, a.paths.NvimConfig); err != nil {
			return err
		}
	} else if !samePath(managedNvim, a.paths.NvimConfig) {
		if err := a.link(managedNvim, a.paths.NvimConfig); err != nil {
			return err
		}
	}
	return a.reloadTmux(ctx, "Reloaded the active tmux server")
}

func (a *App) Capture(ctx context.Context, paths []string) error {
	if err := a.requireActualRepository("capture"); err != nil {
		return err
	}
	chezmoi, err := a.chezmoiPath()
	if err != nil {
		return err
	}
	a.logf("Capturing managed configuration changes")
	arguments := []string{"--source", a.repoRoot, "--destination", a.paths.Home, "re-add"}
	arguments = append(arguments, paths...)
	if err := a.run(ctx, chezmoi, arguments...); err != nil {
		return err
	}
	a.logf("Capture complete; review the repository diff before committing")
	return nil
}

func (a *App) chezmoiDiff(ctx context.Context) (string, error) {
	chezmoi, err := a.chezmoiPath()
	if err != nil {
		return "", err
	}
	return a.output(ctx, chezmoi, "--source", a.repoRoot, "--destination", a.paths.Home, "--no-pager", "diff")
}

func (a *App) requireChezmoiClean(ctx context.Context, operation string) error {
	difference, err := a.chezmoiDiff(ctx)
	if err != nil {
		return err
	}
	if difference != "" {
		return fmt.Errorf("capture or apply managed configuration changes before %s", operation)
	}
	return nil
}
