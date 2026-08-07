package app

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
)

type tmuxPlugin struct {
	Name       string
	Repository string
	Revision   string
}

var (
	tmuxNamePattern     = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
	tmuxRevisionPattern = regexp.MustCompile(`^[0-9a-f]{40}$`)
)

func (a *App) readTmuxLock() ([]tmuxPlugin, error) {
	file, err := os.Open(filepath.Join(a.repoRoot, "manifests", "tmux-plugins.lock"))
	if err != nil {
		return nil, fmt.Errorf("open tmux plugin lockfile: %w", err)
	}
	defer file.Close()
	var plugins []tmuxPlugin
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Split(line, "|")
		if len(parts) != 3 {
			return nil, fmt.Errorf("invalid tmux plugin lock entry: %q", line)
		}
		plugin := tmuxPlugin{Name: parts[0], Repository: parts[1], Revision: parts[2]}
		if !tmuxNamePattern.MatchString(plugin.Name) {
			return nil, fmt.Errorf("invalid tmux plugin name: %s", plugin.Name)
		}
		if !strings.HasPrefix(plugin.Repository, "https://github.com/") || !strings.HasSuffix(plugin.Repository, ".git") {
			return nil, fmt.Errorf("invalid tmux plugin repository for %s", plugin.Name)
		}
		if !tmuxRevisionPattern.MatchString(plugin.Revision) {
			return nil, fmt.Errorf("invalid tmux plugin revision for %s", plugin.Name)
		}
		plugins = append(plugins, plugin)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(plugins) == 0 {
		return nil, fmt.Errorf("tmux plugin lockfile contains no plugins")
	}
	return plugins, nil
}

func (a *App) RestoreTmux(ctx context.Context) error {
	if runtime.GOOS == "windows" {
		return nil
	}
	if _, err := execLookPath("git"); err != nil {
		return fmt.Errorf("required command not found: git")
	}
	plugins, err := a.readTmuxLock()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(a.paths.TmuxPlugins, 0o755); err != nil {
		return err
	}
	for _, plugin := range plugins {
		target := filepath.Join(a.paths.TmuxPlugins, plugin.Name)
		if pathExists(target) {
			if !directory(filepath.Join(target, ".git")) {
				return fmt.Errorf("%s exists but is not a Git checkout", target)
			}
			status, err := a.output(ctx, "git", "-C", target, "status", "--porcelain")
			if err != nil {
				return err
			}
			if status != "" {
				return fmt.Errorf("%s has local changes; preserve or discard them before restoring", plugin.Name)
			}
			if _, err := a.output(ctx, "git", "-C", target, "cat-file", "-e", plugin.Revision+"^{commit}"); err != nil {
				a.logf("Fetching locked tmux plugin: %s", plugin.Name)
				if err := a.run(ctx, "git", "-C", target, "fetch", "--quiet", plugin.Repository, plugin.Revision); err != nil {
					return err
				}
			}
		} else {
			a.logf("Cloning locked tmux plugin: %s", plugin.Name)
			temporary := filepath.Join(a.paths.TmuxPlugins, fmt.Sprintf(".%s.tmp.%d", plugin.Name, os.Getpid()))
			_ = os.RemoveAll(temporary)
			if err := a.run(ctx, "git", "clone", "--quiet", "--no-checkout", plugin.Repository, temporary); err != nil {
				_ = os.RemoveAll(temporary)
				return err
			}
			if err := a.run(ctx, "git", "-C", temporary, "checkout", "--quiet", "--detach", plugin.Revision); err != nil {
				_ = os.RemoveAll(temporary)
				return err
			}
			if err := os.Rename(temporary, target); err != nil {
				_ = os.RemoveAll(temporary)
				return err
			}
		}
		if err := a.run(ctx, "git", "-C", target, "checkout", "--quiet", "--detach", "--force", plugin.Revision); err != nil {
			return err
		}
		actual, err := a.output(ctx, "git", "-C", target, "rev-parse", "HEAD")
		if err != nil {
			return err
		}
		if actual != plugin.Revision {
			return fmt.Errorf("%s did not restore to %s", plugin.Name, plugin.Revision)
		}
		a.logf("Restored tmux plugin: %s %s", plugin.Name, plugin.Revision[:12])
	}
	if err := a.reloadTmux(ctx, "Reloaded tmux2k in the active tmux server"); err != nil {
		return err
	}
	a.logf("tmux plugins match manifests/tmux-plugins.lock")
	return nil
}

func (a *App) reloadTmux(ctx context.Context, message string) error {
	if runtime.GOOS == "windows" {
		return nil
	}
	if _, err := execLookPath("tmux"); err != nil {
		return nil
	}
	if _, err := a.output(ctx, "tmux", "list-sessions"); err != nil {
		return nil
	}
	if err := a.run(ctx, "tmux", "source-file", filepath.Join(a.paths.Home, ".tmux.conf")); err != nil {
		return err
	}
	a.logf("%s", message)
	return nil
}
