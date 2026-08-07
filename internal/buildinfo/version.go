package buildinfo

import (
	"runtime/debug"
	"strings"
)

var version = "dev"

// Version returns an injected release version or Go's embedded VCS revision.
func Version() string {
	var revision string
	modified := false
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, setting := range info.Settings {
			switch setting.Key {
			case "vcs.revision":
				revision = setting.Value
			case "vcs.modified":
				modified = setting.Value == "true"
			}
		}
	}
	return resolveVersion(version, revision, modified)
}

func resolveVersion(injected, revision string, modified bool) string {
	if injected != "" && injected != "dev" {
		return injected
	}
	if revision == "" {
		return "dev"
	}
	if len(revision) > 12 {
		revision = revision[:12]
	}
	if modified && !strings.HasSuffix(revision, "-dirty") {
		revision += "-dirty"
	}
	return revision
}

// Variable returns the linker variable used by repository build commands.
func Variable() string {
	return "github.com/savioserra/lazyvim/internal/buildinfo.version"
}
