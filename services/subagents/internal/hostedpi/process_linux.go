//go:build linux

package hostedpi

import (
	"context"
	"fmt"
	"os"
	"strings"
)

func processStartToken(ctx context.Context, pid int64) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	contents, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if err != nil {
		return "", err
	}
	line := string(contents)
	close := strings.LastIndex(line, ")")
	if close < 0 {
		return "", fmt.Errorf("malformed /proc stat")
	}
	fields := strings.Fields(line[close+1:])
	// /proc stat field 22; fields starts at field 3 after the comm value.
	if len(fields) < 20 || fields[19] == "" {
		return "", fmt.Errorf("missing /proc process start time")
	}
	return fields[19], nil
}
