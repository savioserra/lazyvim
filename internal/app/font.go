package app

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"

	archiveutil "github.com/savioserra/lazyvim/internal/archive"
	"github.com/savioserra/lazyvim/internal/download"
)

func (a *App) installFont(ctx context.Context) error {
	font := a.catalog.Font
	artifact := download.Artifact{URL: font.URL, SHA256: font.SHA256, FileName: font.ArchiveName}
	marker := filepath.Join(a.paths.State, "fonts", "JetBrainsMono-"+font.Version+".installed")
	regular := a.fontRegularPath()
	if markerContent, err := os.ReadFile(marker); err == nil && strings.TrimSpace(string(markerContent)) == font.Version && fontContainsVersion(regular, font.Version) {
		a.logf("Already installed: JetBrainsMono Nerd Font %s", font.Version)
		return nil
	}
	archivePath, err := a.downloader.Fetch(ctx, artifact, a.paths.DownloadCache)
	if err != nil {
		return err
	}
	temporary, err := os.MkdirTemp("", "dotfiles-fonts-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temporary)
	if err := archiveutil.Extract(archivePath, temporary, font.ArchiveKind, "", ""); err != nil {
		return fmt.Errorf("extract Nerd Font: %w", err)
	}

	switch runtime.GOOS {
	case "linux":
		target := filepath.Join(a.paths.Data, "fonts", "JetBrainsMonoNerdFont")
		if pathExists(target) {
			if err := a.backup(target); err != nil {
				return err
			}
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		if err := moveDirectory(temporary, target); err != nil {
			return err
		}
		if _, err := execLookPath("fc-cache"); err == nil {
			if err := a.run(ctx, "fc-cache", "-f", target); err != nil {
				return err
			}
		}
	case "darwin", "windows":
		fontHome := filepath.Dir(regular)
		if err := os.MkdirAll(fontHome, 0o755); err != nil {
			return err
		}
		err := filepath.WalkDir(temporary, func(path string, entry os.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			if entry.IsDir() || !strings.EqualFold(filepath.Ext(entry.Name()), ".ttf") {
				return nil
			}
			destination := filepath.Join(fontHome, entry.Name())
			if pathExists(destination) {
				if err := a.backup(destination); err != nil {
					return err
				}
			}
			if err := copyFile(path, destination, 0o644); err != nil {
				return err
			}
			if runtime.GOOS == "windows" {
				valueName := strings.TrimSuffix(entry.Name(), filepath.Ext(entry.Name())) + " (TrueType)"
				if err := a.run(ctx, "reg.exe", "add", `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts`, "/v", valueName, "/t", "REG_SZ", "/d", destination, "/f"); err != nil {
					return err
				}
			}
			return nil
		})
		if err != nil {
			return err
		}
	default:
		return fmt.Errorf("font installation is unsupported on %s", runtime.GOOS)
	}
	if !fontContainsVersion(regular, font.Version) {
		return fmt.Errorf("JetBrainsMono Nerd Font did not install correctly: %s does not report version %s", regular, font.Version)
	}
	if runtime.GOOS == "windows" {
		if err := notifyWindowsFontChange(); err != nil {
			a.warnf("could not notify running applications about the new fonts: %v", err)
		}
	}
	if err := os.MkdirAll(filepath.Dir(marker), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(marker, []byte(font.Version+"\n"), 0o644); err != nil {
		return err
	}
	a.logf("Installed JetBrainsMono Nerd Font %s", font.Version)
	return nil
}

func fontContainsVersion(path, version string) bool {
	content, err := os.ReadFile(path)
	return err == nil && bytes.Contains(content, []byte("Nerd Fonts "+version))
}

func (a *App) fontRegularPath() string {
	switch runtime.GOOS {
	case "linux":
		return filepath.Join(a.paths.Data, "fonts", "JetBrainsMonoNerdFont", "JetBrainsMonoNerdFont-Regular.ttf")
	case "darwin":
		return filepath.Join(a.paths.Home, "Library", "Fonts", "JetBrainsMonoNerdFont-Regular.ttf")
	case "windows":
		return filepath.Join(os.Getenv("LOCALAPPDATA"), "Microsoft", "Windows", "Fonts", "JetBrainsMonoNerdFont-Regular.ttf")
	default:
		return ""
	}
}
