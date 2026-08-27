//go:build darwin

package socket

import (
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
)

func processStartToken(pid int) (string, error) {
	output, err := exec.Command("ps", "-o", "lstart=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return "", err
	}
	token := strings.Join(strings.Fields(string(output)), " ")
	if token == "" {
		return "", fmt.Errorf("empty process start token for pid %d", pid)
	}
	return token, nil
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
