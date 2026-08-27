//go:build linux

package socket

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"syscall"
)

func processStartToken(pid int) (string, error) {
	contents, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return "", err
	}
	closing := strings.LastIndexByte(string(contents), ')')
	if closing < 0 {
		return "", fmt.Errorf("malformed process stat for pid %d", pid)
	}
	fields := strings.Fields(string(contents[closing+1:]))
	if len(fields) <= 19 {
		return "", fmt.Errorf("incomplete process stat for pid %d", pid)
	}
	if _, err := strconv.ParseUint(fields[19], 10, 64); err != nil {
		return "", fmt.Errorf("invalid process start token: %w", err)
	}
	return fields[19], nil
}

func lookupProcessIdentity(pid int, expected string) processIdentityState {
	token, err := processStartToken(pid)
	if err == nil {
		if token == expected {
			return processActive
		}
		return processDead
	}
	if killErr := syscall.Kill(pid, 0); errors.Is(killErr, syscall.ESRCH) {
		return processDead
	}
	return processIndeterminate
}
