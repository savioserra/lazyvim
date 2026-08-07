package app

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"go/format"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"

	"github.com/savioserra/lazyvim/internal/host"
)

func (a *App) Check(ctx context.Context) error {
	if _, err := execLookPath("git"); err != nil {
		return fmt.Errorf("required command not found: git")
	}
	if a.actualRepo {
		a.logf("Checking Go source formatting")
		if err := a.checkGoFormatting(); err != nil {
			return err
		}
	}
	a.logf("Checking JSON files")
	if err := filepath.WalkDir(filepath.Join(a.repoRoot, "home", "dot_config", "nvim"), func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() || !strings.EqualFold(filepath.Ext(entry.Name()), ".json") {
			return nil
		}
		content, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var value any
		if err := json.Unmarshal(content, &value); err != nil {
			return fmt.Errorf("invalid JSON in %s: %w", path, err)
		}
		return nil
	}); err != nil {
		return err
	}

	nvim, err := a.nvimPath()
	if err != nil {
		return err
	}
	a.logf("Checking pinned Neovim")
	nvimVersion, err := a.output(ctx, nvim, "--version")
	if err != nil {
		return err
	}
	first := firstLine(nvimVersion)
	actualNvim := strings.TrimPrefix(first, "NVIM v")
	if actualNvim != a.tools["NEOVIM_VERSION"] {
		return fmt.Errorf("expected Neovim %s, found %s", a.tools["NEOVIM_VERSION"], actualNvim)
	}
	chezmoi, err := a.chezmoiPath()
	if err != nil {
		return err
	}
	if err := a.checkReleaseLauncher("chezmoi", chezmoi); err != nil {
		return err
	}
	chezmoiVersion, err := a.output(ctx, chezmoi, "--version")
	if err != nil {
		return err
	}
	if !strings.Contains(firstLine(chezmoiVersion), "chezmoi version v"+a.tools["CHEZMOI_VERSION"]+",") {
		return fmt.Errorf("chezmoi does not match version %s", a.tools["CHEZMOI_VERSION"])
	}

	a.logf("Checking chezmoi source and target state")
	difference, err := a.chezmoiDiff(ctx)
	if err != nil {
		return err
	}
	if difference != "" {
		return fmt.Errorf("managed configuration differs from the repository; run dotfiles capture or dotfiles apply")
	}
	if err := a.checkCompanionVersions(ctx); err != nil {
		return err
	}
	if err := a.checkConfigTarget(); err != nil {
		return err
	}
	if err := a.checkStylua(ctx); err != nil {
		return err
	}
	if err := a.checkMason(); err != nil {
		return err
	}
	a.logf("Checking installed plugin revisions")
	if err := a.run(ctx, nvim, "--headless", "+lua require('dotfiles.restore').plugins()", "+qa"); err != nil {
		return err
	}
	if runtime.GOOS != "windows" {
		if err := a.checkTmux(ctx); err != nil {
			return err
		}
	}
	a.logf("Checking headless startup")
	if err := a.run(ctx, nvim, "--headless", "+lua assert(vim.g.lazyvim_ts_lsp == 'vtsls', 'LazyVim options were not loaded'); assert(vim.g.colors_name == 'catppuccin' and require('catppuccin').options.flavour == 'macchiato', 'Catppuccin Macchiato was not loaded')", "+qa"); err != nil {
		return err
	}
	a.logf("All checks passed")
	return nil
}

func (a *App) checkGoFormatting() error {
	return filepath.WalkDir(a.repoRoot, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			if entry.Name() == ".git" || entry.Name() == ".build" {
				return filepath.SkipDir
			}
			return nil
		}
		if filepath.Ext(entry.Name()) != ".go" {
			return nil
		}
		content, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		formatted, err := format.Source(content)
		if err != nil {
			return fmt.Errorf("invalid Go source %s: %w", path, err)
		}
		if !bytes.Equal(content, formatted) {
			return fmt.Errorf("Go source is not formatted: %s", path)
		}
		return nil
	})
}

func (a *App) checkCompanionVersions(ctx context.Context) error {
	a.logf("Checking companion tool versions")
	for _, name := range []string{"ripgrep", "fd", "fzf", "lazygit", "tree-sitter"} {
		release, ok := a.catalog.Release(name)
		if !ok {
			return fmt.Errorf("missing %s catalog entry", name)
		}
		path := a.executable(release)
		if !executableFile(path) {
			return fmt.Errorf("managed companion tool is missing or not executable: %s", path)
		}
		if err := a.checkReleaseLauncher(releaseCommandName(release), path); err != nil {
			return err
		}
		output, err := a.output(ctx, path, "--version")
		if err != nil {
			return err
		}
		first := firstLine(output)
		switch name {
		case "ripgrep":
			if !strings.HasPrefix(first, "ripgrep "+release.Version) {
				return fmt.Errorf("ripgrep does not match version %s", release.Version)
			}
		case "fd":
			if first != "fd "+release.Version {
				return fmt.Errorf("fd does not match version %s", release.Version)
			}
		case "fzf":
			if first != release.Version && !strings.HasPrefix(first, release.Version+" ") {
				return fmt.Errorf("fzf does not match version %s", release.Version)
			}
		case "lazygit":
			matched, _ := regexp.MatchString(`version=`+regexp.QuoteMeta(release.Version)+`(?:,|$)`, output)
			if !matched {
				return fmt.Errorf("lazygit does not match version %s", release.Version)
			}
		case "tree-sitter":
			if first != "tree-sitter "+release.Version {
				return fmt.Errorf("tree-sitter does not match version %s", release.Version)
			}
		}
	}
	return nil
}

func (a *App) checkReleaseLauncher(name, expected string) error {
	if runtime.GOOS == "windows" {
		launcher := filepath.Join(a.paths.Bin, name+".cmd")
		content, err := os.ReadFile(launcher)
		if err != nil {
			return fmt.Errorf("managed command shim is missing: %s", launcher)
		}
		if !strings.Contains(string(content), escapeBatchLiteral(expected)) {
			return fmt.Errorf("managed command shim %s does not target %s", launcher, expected)
		}
		return nil
	}
	launcher := filepath.Join(a.paths.Bin, name)
	resolved, err := filepath.EvalSymlinks(launcher)
	if err != nil {
		return fmt.Errorf("managed command link is missing: %s", launcher)
	}
	if !samePath(resolved, expected) {
		return fmt.Errorf("managed command link %s points to %s, expected %s", launcher, resolved, expected)
	}
	return nil
}

func (a *App) checkConfigTarget() error {
	if !directory(a.paths.NvimConfig) {
		return fmt.Errorf("managed Neovim configuration is missing: %s", a.paths.NvimConfig)
	}
	expected := filepath.Join(a.paths.Home, ".config", "nvim")
	if samePath(a.paths.NvimConfig, expected) {
		return nil
	}
	resolved, err := filepath.EvalSymlinks(a.paths.NvimConfig)
	if err != nil {
		return fmt.Errorf("resolve managed Neovim configuration %s: %w", a.paths.NvimConfig, err)
	}
	if !samePath(resolved, expected) {
		return fmt.Errorf("%s resolves to %s, expected %s; run dotfiles install", a.paths.NvimConfig, resolved, expected)
	}
	return nil
}

func (a *App) checkStylua(ctx context.Context) error {
	mason := filepath.Join(a.paths.NvimData, "mason")
	candidates := []string{filepath.Join(mason, "bin", "stylua")}
	if runtime.GOOS == "windows" {
		candidates = []string{filepath.Join(mason, "bin", "stylua.cmd"), filepath.Join(mason, "bin", "stylua.exe")}
	}
	for _, stylua := range candidates {
		if regularFile(stylua) {
			a.logf("Checking Lua formatting")
			luaDirectory := filepath.Join(a.repoRoot, "home", "dot_config", "nvim", "lua")
			if runtime.GOOS == "windows" && strings.EqualFold(filepath.Ext(stylua), ".cmd") {
				return a.runWithEnvironment(ctx, []string{"DOTFILES_STYLUA=" + stylua, "DOTFILES_LUA_DIR=" + luaDirectory}, "cmd.exe", "/d", "/v:off", "/s", "/c", `"%DOTFILES_STYLUA%" --check "%DOTFILES_LUA_DIR%"`)
			}
			return a.run(ctx, stylua, "--check", luaDirectory)
		}
	}
	a.warnf("Stylua is not installed; skipping Lua formatting check")
	return nil
}

func (a *App) checkMason() error {
	lock, err := readMasonLock(filepath.Join(a.repoRoot, "home", "dot_config", "nvim", "mason-lock.json"))
	if err != nil {
		return err
	}
	if len(lock) == 0 {
		return nil
	}
	packagesHome := filepath.Join(a.paths.NvimData, "mason", "packages")
	if !directory(packagesHome) {
		return fmt.Errorf("Mason package directory is missing: %s; run dotfiles restore", packagesHome)
	}
	a.logf("Checking installed Mason versions")
	for _, name := range sortedKeys(lock) {
		expected := lock[name]
		packageHome := filepath.Join(packagesHome, name)
		if !directory(packageHome) {
			return fmt.Errorf("locked Mason package is missing: %s; run dotfiles restore", name)
		}
		receiptPath := filepath.Join(packageHome, "mason-receipt.json")
		if !regularFile(receiptPath) {
			return fmt.Errorf("Mason package %s has no receipt: %s; run dotfiles restore", name, receiptPath)
		}
		receipt, err := readMasonReceipt(receiptPath)
		if err != nil {
			return err
		}
		if receipt.Name != name {
			return fmt.Errorf("Mason receipt %s identifies %q, expected %q", receiptPath, receipt.Name, name)
		}
		actual, err := masonReceiptVersion(receipt, receiptPath)
		if err != nil {
			return err
		}
		if actual != expected {
			return fmt.Errorf("Mason package %s is %s; lockfile requires %s", name, actual, expected)
		}
	}
	return nil
}

func (a *App) checkTmux(ctx context.Context) (returnErr error) {
	if _, err := execLookPath("tmux"); err != nil {
		a.warnf("tmux is not installed; skipping tmux configuration check")
		return nil
	}
	a.logf("Checking locked tmux plugins and configuration")
	bashVersion, err := a.output(ctx, "bash", "--version")
	if err != nil {
		return fmt.Errorf("tmux2k requires Bash 5.2 or newer: %w", err)
	}
	major, minor, err := parseBashVersion(firstLine(bashVersion))
	if err != nil {
		return err
	}
	if major < 5 || major == 5 && minor < 2 {
		return fmt.Errorf("tmux2k requires Bash 5.2 or newer; found %d.%d", major, minor)
	}
	plugins, err := a.readTmuxLock()
	if err != nil {
		return err
	}
	for _, plugin := range plugins {
		target := filepath.Join(a.paths.TmuxPlugins, plugin.Name)
		if !directory(filepath.Join(target, ".git")) {
			return fmt.Errorf("locked tmux plugin is missing: %s; run dotfiles restore-tmux", plugin.Name)
		}
		actual, err := a.output(ctx, "git", "-C", target, "rev-parse", "HEAD")
		if err != nil {
			return err
		}
		if actual != plugin.Revision {
			return fmt.Errorf("tmux plugin %s is %s; lockfile requires %s", plugin.Name, actual, plugin.Revision)
		}
	}

	socket := fmt.Sprintf("dotfiles-check-%d", os.Getpid())
	tmux := func(arguments ...string) (string, error) {
		command := append([]string{"-L", socket}, arguments...)
		return a.outputWithEnvironment(ctx, []string{"TMUX="}, "tmux", command...)
	}
	defer func() {
		_, _ = tmux("kill-server")
	}()
	if _, err := tmux("-f", filepath.Join(a.paths.Home, ".tmux.conf"), "new-session", "-d", "-s", "dotfiles-check"); err != nil {
		return err
	}
	checks := []struct {
		arguments []string
		expected  string
		message   string
	}{
		{[]string{"show-options", "-gqv", "mouse"}, "on", "tmux mouse support is not enabled"},
		{[]string{"show-options", "-sqv", "escape-time"}, "10", "tmux escape-time is not 10ms"},
		{[]string{"show-options", "-gqv", "focus-events"}, "on", "tmux focus events are not enabled"},
		{[]string{"show-options", "-gqv", "default-terminal"}, "tmux-256color", "tmux default terminal is not tmux-256color"},
		{[]string{"show-options", "-sqv", "terminal-features[100]"}, "xterm-256color:RGB", "tmux true-color support is not configured"},
		{[]string{"show-options", "-gqv", "@tmux2k-theme"}, "catppuccin", "tmux2k Catppuccin theme is not configured"},
		{[]string{"show-options", "-gqv", "@tmux2k-left-plugins"}, "session git cwd", "tmux2k left status extensions do not match the repository"},
		{[]string{"show-options", "-gqv", "@tmux2k-right-plugins"}, "cpu ram time", "tmux2k right status extensions do not match the repository"},
		{[]string{"show-options", "-gqv", "@tmux2k-cpu-gradient"}, "", "tmux2k CPU gradient reduces status contrast"},
		{[]string{"show-options", "-gqv", "@tmux2k-ram-gradient"}, "", "tmux2k RAM gradient reduces status contrast"},
		{[]string{"show-options", "-gqv", "@tmux2k-ram-icon"}, "", "tmux2k RAM icon does not match the repository"},
	}
	for _, check := range checks {
		actual, err := tmux(check.arguments...)
		if err != nil {
			return err
		}
		if actual != check.expected {
			return fmt.Errorf("%s", check.message)
		}
	}
	status, err := tmux("show-options", "-gqv", "status-left")
	if err != nil {
		return err
	}
	if !strings.Contains(status, "/tmux2k/plugins/") {
		return fmt.Errorf("tmux2k did not initialize the status bar")
	}
	_, err = tmux("kill-server")
	return err
}

func (a *App) outputWithEnvironment(ctx context.Context, environment []string, name string, arguments ...string) (string, error) {
	result, err := a.runner.Output(ctx, host.Command{Name: name, Args: arguments, Env: environmentOverrides(os.Environ(), environment)})
	if err != nil {
		return "", commandError(name, arguments, err, result.Stderr)
	}
	return strings.TrimSpace(result.Stdout), nil
}

var bashVersionPattern = regexp.MustCompile(`version ([0-9]+)\.([0-9]+)`)

func parseBashVersion(line string) (int, int, error) {
	matches := bashVersionPattern.FindStringSubmatch(line)
	if len(matches) != 3 {
		return 0, 0, fmt.Errorf("could not parse Bash version: %s", line)
	}
	major, _ := strconv.Atoi(matches[1])
	minor, _ := strconv.Atoi(matches[2])
	return major, minor, nil
}

func firstLine(value string) string {
	if before, _, ok := strings.Cut(value, "\n"); ok {
		return strings.TrimSpace(before)
	}
	return strings.TrimSpace(value)
}
