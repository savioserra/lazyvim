//go:build windows

package app

import (
	"context"
	"io"
	"os/exec"
)

func replaceProcess(ctx context.Context, path string, arguments, environment []string, in io.Reader, out, stderr io.Writer) error {
	command := exec.CommandContext(ctx, path, arguments[1:]...)
	command.Env = environment
	command.Stdin = in
	command.Stdout = out
	command.Stderr = stderr
	return command.Run()
}
