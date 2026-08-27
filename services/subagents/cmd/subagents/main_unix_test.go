//go:build linux || darwin

package main

import (
	"path/filepath"
	"strings"
	"testing"

	workstationsocket "github.com/savioserra/lazyvim/services/subagents/internal/socket"
)

func TestRelativeSocketFlagCannotBypassWindowsMountPolicy(t *testing.T) {
	normalizeFromWindowsMount := func(path string) (string, error) {
		if !filepath.IsAbs(path) {
			path = filepath.Join("/mnt/c/workstation", path)
		}
		return workstationsocket.NormalizePrivatePath(path)
	}
	_, _, err := normalizeCLIPaths("/tmp/config.toml", "runtime/control.sock", normalizeFromWindowsMount)
	if err == nil || !strings.Contains(err.Error(), "socket path") {
		t.Fatalf("relative --socket bypassed /mnt policy: %v", err)
	}
}
