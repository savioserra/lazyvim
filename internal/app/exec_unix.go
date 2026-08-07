//go:build !windows

package app

import (
	"context"
	"io"
	"syscall"
)

func replaceProcess(_ context.Context, path string, arguments, environment []string, _ io.Reader, _, _ io.Writer) error {
	return syscall.Exec(path, arguments, environment)
}
