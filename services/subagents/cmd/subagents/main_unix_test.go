//go:build linux || darwin

package main

import (
	"path/filepath"
	"strings"
	"testing"

	workstationsocket "github.com/savioserra/lazyvim/services/subagents/internal/socket"
)

func TestRelativeConfigFlagCannotBypassWindowsMountPolicy(t *testing.T) {
	normalizeFromWindowsMount := func(path string) (string, error) {
		if !filepath.IsAbs(path) {
			path = filepath.Join("/mnt/c/workstation", path)
		}
		return workstationsocket.NormalizePrivatePath(path)
	}
	_, err := normalizeFromWindowsMount("config.toml")
	if err == nil || !strings.Contains(err.Error(), "Windows-mounted") {
		t.Fatalf("relative config path bypassed /mnt policy: %v", err)
	}
}
