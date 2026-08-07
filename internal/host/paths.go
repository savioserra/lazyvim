package host

import (
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/savioserra/lazyvim/internal/config"
)

// Paths contains all platform-resolved filesystem locations used by the CLI.
type Paths struct {
	Home          string
	Opt           string
	Bin           string
	Config        string
	Data          string
	Cache         string
	State         string
	DownloadCache string
	NvimConfig    string
	NvimData      string
	TmuxPlugins   string
}

func ResolvePaths(platform config.Platform) (Paths, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return Paths{}, err
	}
	paths := Paths{Home: home}
	if platform.GOOS == "windows" {
		local := os.Getenv("LOCALAPPDATA")
		if local == "" {
			return Paths{}, errors.New("LOCALAPPDATA is not set")
		}
		paths.Opt = EnvironmentOr("DOTFILES_OPT_HOME", filepath.Join(local, "Programs", "dotfiles"))
		paths.Bin = EnvironmentOr("DOTFILES_BIN_HOME", filepath.Join(paths.Opt, "bin"))
		paths.Config = local
		paths.Data = local
		paths.Cache = filepath.Join(local, "dotfiles", "cache")
		paths.State = filepath.Join(local, "dotfiles", "state")
		paths.NvimConfig = filepath.Join(local, "nvim")
		paths.NvimData = filepath.Join(local, "nvim-data")
	} else {
		paths.Opt = EnvironmentOr("DOTFILES_OPT_HOME", filepath.Join(home, ".local", "opt"))
		paths.Bin = EnvironmentOr("DOTFILES_BIN_HOME", filepath.Join(home, ".local", "bin"))
		paths.Config = EnvironmentOr("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
		paths.Data = NormalizedDataHome(home, EnvironmentOr("XDG_DATA_HOME", filepath.Join(home, ".local", "share")))
		paths.Cache = EnvironmentOr("XDG_CACHE_HOME", filepath.Join(home, ".cache"))
		paths.State = filepath.Join(EnvironmentOr("XDG_STATE_HOME", filepath.Join(home, ".local", "state")), "dotfiles")
		paths.NvimConfig = filepath.Join(paths.Config, "nvim")
		paths.NvimData = filepath.Join(paths.Data, "nvim")
		paths.TmuxPlugins = EnvironmentOr("TMUX_PLUGIN_HOME", filepath.Join(home, ".tmux", "plugins"))
	}
	paths.DownloadCache = filepath.Join(paths.Cache, "dotfiles", "downloads")
	if platform.GOOS == "windows" {
		paths.DownloadCache = filepath.Join(paths.Cache, "downloads")
	}
	return paths, nil
}

func EnvironmentOr(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func NormalizedDataHome(home, value string) string {
	clean := filepath.ToSlash(filepath.Clean(value))
	prefix := filepath.ToSlash(filepath.Join(home, "snap", "code")) + "/"
	if strings.HasPrefix(clean, prefix) && strings.HasSuffix(clean, "/.local/share") {
		return filepath.Join(home, ".local", "share")
	}
	return value
}
