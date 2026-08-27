//go:build darwin

package hostedpi

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
)

func processStartToken(ctx context.Context, pid int64) (string, error) {
	output, err := exec.CommandContext(ctx, "/bin/ps", "-o", "lstart=", "-p", fmt.Sprint(pid)).Output()
	if err != nil {
		return "", err
	}
	token := strings.Join(strings.Fields(string(output)), " ")
	if token == "" {
		return "", fmt.Errorf("missing process start time")
	}
	return token, nil
}
