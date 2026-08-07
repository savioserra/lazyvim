package app

import (
	"context"
	"debug/elf"
	"debug/macho"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	archiveutil "github.com/savioserra/lazyvim/internal/archive"
	"github.com/savioserra/lazyvim/internal/config"
	"github.com/savioserra/lazyvim/internal/download"
)

type InstallOptions struct {
	Minimal   bool
	NoFont    bool
	NoRestore bool
	Offline   bool
}

func (a *App) Install(ctx context.Context, options InstallOptions) error {
	if options.Offline && !options.NoRestore {
		return fmt.Errorf("offline installation requires --no-restore because plugin, Mason, parser, and tmux restoration may need the network")
	}
	a.downloader.SetOffline(options.Offline)
	defer a.downloader.SetOffline(false)
	if err := a.rememberRepository(); err != nil {
		return fmt.Errorf("remember repository: %w", err)
	}
	for _, directory := range []string{a.paths.Opt, a.paths.Bin, a.paths.Config, a.paths.DownloadCache, a.paths.State} {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			return fmt.Errorf("create %s: %w", directory, err)
		}
	}
	if !options.NoRestore {
		if _, err := execLookPath("git"); err != nil {
			return fmt.Errorf("Git is required to restore plugins; install Git or use --no-restore")
		}
	}

	companions := !options.Minimal
	for _, release := range a.catalog.Releases {
		if !companions && release.Name != "nvim" && release.Name != "chezmoi" {
			continue
		}
		if _, err := a.installRelease(ctx, release); err != nil {
			return err
		}
	}
	if !options.Minimal && !options.NoFont {
		if err := a.installFont(ctx); err != nil {
			return err
		}
	}
	if err := a.migrateAndApply(ctx); err != nil {
		return err
	}

	self, err := a.installSelf()
	if err != nil {
		return err
	}
	if err := a.writeCommandShim("dotfiles", self); err != nil {
		return err
	}
	if runtime.GOOS == "windows" {
		if err := a.writeCommandShim("nvim", self, "nvim"); err != nil {
			return err
		}
	} else if err := a.writeCommandShim("nvim", self); err != nil {
		return err
	}
	for _, release := range a.catalog.Releases {
		if release.Name == "nvim" {
			continue
		}
		if !companions && release.Name != "chezmoi" {
			continue
		}
		if err := a.writeCommandShim(releaseCommandName(release), a.executable(release)); err != nil {
			return err
		}
	}
	if runtime.GOOS == "windows" {
		if err := a.addUserPath(a.paths.Bin); err != nil {
			return err
		}
	}
	if !options.NoRestore {
		if err := a.Restore(ctx, RestoreOptions{}); err != nil {
			return err
		}
	}
	a.logf("Installation complete for %s", a.platform.ID)
	if runtime.GOOS == "windows" {
		fmt.Fprintln(a.out, "Open a new terminal, then run: nvim")
	} else {
		fmt.Fprintf(a.out, "Ensure %s is in PATH, then run: nvim\n", a.paths.Bin)
	}
	return nil
}

func (a *App) installRelease(ctx context.Context, release config.Release) (string, error) {
	target := filepath.Join(a.paths.Opt, release.TargetName)
	marker := filepath.Join(target, ".dotfiles-release")
	installedBinary := filepath.Join(target, filepath.FromSlash(release.ExpectedBinary))
	if executableFile(installedBinary) {
		if content, err := os.ReadFile(marker); err == nil && strings.TrimSpace(string(content)) == release.ReleaseIdentity() {
			a.logf("Already installed: %s %s", release.Name, release.Version)
			return target, nil
		}
		if !regularFile(marker) && release.Platform.GOOS != "windows" && legacyBinaryMatches(filepath.Join(target, filepath.FromSlash(release.ExpectedBinary)), release.Platform) {
			if err := os.WriteFile(marker, []byte(release.ReleaseIdentity()+"\n"), 0o644); err != nil {
				return "", err
			}
			a.logf("Recorded release identity for existing %s %s", release.Name, release.Version)
			return target, nil
		}
	}
	artifact := download.Artifact{URL: release.URL, SHA256: release.SHA256, FileName: release.ArchiveName}
	archivePath, err := a.downloader.Fetch(ctx, artifact, a.paths.DownloadCache)
	if err != nil {
		return "", err
	}
	temporary, err := os.MkdirTemp(a.paths.Opt, "."+release.Name+"-install-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(temporary)
	if err := archiveutil.Extract(archivePath, temporary, release.ArchiveKind, release.StripPrefix, release.DestinationPrefix); err != nil {
		return "", fmt.Errorf("extract %s: %w", release.Name, err)
	}
	expected := filepath.Join(temporary, filepath.FromSlash(release.ExpectedBinary))
	if !regularFile(expected) {
		return "", fmt.Errorf("%s archive did not contain %s", release.Name, release.ExpectedBinary)
	}
	if release.Platform.GOOS != "windows" {
		if err := os.Chmod(expected, 0o755); err != nil {
			return "", err
		}
		if release.Platform.GOOS == "darwin" {
			_ = a.run(ctx, "xattr", "-cr", temporary)
		}
	}
	if !executableFile(expected) {
		return "", fmt.Errorf("%s archive installed a non-executable %s", release.Name, release.ExpectedBinary)
	}
	if err := os.WriteFile(filepath.Join(temporary, ".dotfiles-release"), []byte(release.ReleaseIdentity()+"\n"), 0o644); err != nil {
		return "", err
	}
	backup := ""
	if pathExists(target) {
		backup, err = a.backupWithDestination(target)
		if err != nil {
			return "", err
		}
	}
	if err := os.Rename(temporary, target); err != nil {
		if backup != "" && !pathExists(target) {
			if restoreErr := movePath(backup, target); restoreErr != nil {
				return "", fmt.Errorf("publish %s: %w (also failed to restore backup: %v)", release.Name, err, restoreErr)
			}
		}
		return "", fmt.Errorf("publish %s: %w", release.Name, err)
	}
	a.logf("Installed %s %s", release.Name, release.Version)
	return target, nil
}

func legacyBinaryMatches(path string, platform config.Platform) bool {
	switch platform.GOOS {
	case "linux":
		file, err := elf.Open(path)
		if err != nil {
			return false
		}
		defer file.Close()
		return platform.GOARCH == "amd64" && file.Machine == elf.EM_X86_64
	case "darwin":
		file, err := macho.Open(path)
		if err != nil {
			return false
		}
		defer file.Close()
		return platform.GOARCH == "arm64" && file.Cpu == macho.CpuArm64 || platform.GOARCH == "amd64" && file.Cpu == macho.CpuAmd64
	default:
		return false
	}
}

func execLookPath(name string) (string, error) {
	return exec.LookPath(name)
}

func releaseCommandName(release config.Release) string {
	name := release.ExecutableName()
	return strings.TrimSuffix(name, filepath.Ext(name))
}
