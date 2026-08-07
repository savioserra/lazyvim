package host

import (
	"path/filepath"
	"runtime"
	"testing"

	"github.com/savioserra/lazyvim/internal/config"
)

func TestNormalizedDataHomeRemovesSnapRevisionPath(t *testing.T) {
	home := filepath.Join(string(filepath.Separator), "home", "user")
	snap := filepath.Join(home, "snap", "code", "123", ".local", "share")
	if got, want := NormalizedDataHome(home, snap), filepath.Join(home, ".local", "share"); got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestResolvePathsHonorsUnixOverrides(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("Unix path policy")
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("LAZYVIM_OPT_HOME", filepath.Join(home, "opt"))
	t.Setenv("LAZYVIM_BIN_HOME", filepath.Join(home, "bin"))
	platform, err := config.PlatformFor("linux", "amd64")
	if err != nil {
		t.Fatal(err)
	}
	paths, err := ResolvePaths(platform)
	if err != nil {
		t.Fatal(err)
	}
	if paths.Opt != filepath.Join(home, "opt") || paths.Bin != filepath.Join(home, "bin") {
		t.Fatalf("overrides not applied: %+v", paths)
	}
}
