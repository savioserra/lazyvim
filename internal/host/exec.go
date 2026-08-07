package host

import (
	"bytes"
	"context"
	"io"
	"os/exec"
)

// Command describes a native process without coupling callers to os/exec.
type Command struct {
	Name string
	Args []string
	Dir  string
	Env  []string
	In   io.Reader
	Out  io.Writer
	Err  io.Writer
}

// Output is the captured output of a native process.
type Output struct {
	Stdout string
	Stderr string
}

// Runner executes native processes. Implementations may be replaced in tests.
type Runner interface {
	Run(context.Context, Command) error
	Output(context.Context, Command) (Output, error)
}

// ExecRunner executes processes with os/exec.
type ExecRunner struct{}

func (ExecRunner) Run(ctx context.Context, command Command) error {
	process := exec.CommandContext(ctx, command.Name, command.Args...)
	process.Dir = command.Dir
	process.Env = command.Env
	process.Stdin = command.In
	process.Stdout = command.Out
	process.Stderr = command.Err
	return process.Run()
}

func (ExecRunner) Output(ctx context.Context, command Command) (Output, error) {
	process := exec.CommandContext(ctx, command.Name, command.Args...)
	process.Dir = command.Dir
	process.Env = command.Env
	process.Stdin = command.In
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	process.Stdout = &stdout
	process.Stderr = &stderr
	err := process.Run()
	return Output{Stdout: stdout.String(), Stderr: stderr.String()}, err
}
