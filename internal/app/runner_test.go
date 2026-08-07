package app

import (
	"context"
	"errors"
	"io"
	"testing"

	"github.com/savioserra/lazyvim/internal/host"
)

type recordingRunner struct {
	command host.Command
	output  host.Output
	err     error
}

func (r *recordingRunner) Run(_ context.Context, command host.Command) error {
	r.command = command
	return r.err
}

func (r *recordingRunner) Output(_ context.Context, command host.Command) (host.Output, error) {
	r.command = command
	return r.output, r.err
}

func TestAppDelegatesCommandsToInjectedRunner(t *testing.T) {
	runner := &recordingRunner{}
	application := &App{runner: runner, in: nil, out: io.Discard, err: io.Discard, paths: Paths{Home: t.TempDir()}}
	if err := application.runIn(context.Background(), "/work", "tool", "one", "two"); err != nil {
		t.Fatal(err)
	}
	if runner.command.Name != "tool" || runner.command.Dir != "/work" || len(runner.command.Args) != 2 {
		t.Fatalf("unexpected command: %+v", runner.command)
	}
}

func TestAppPreservesRunnerErrorsAndStderr(t *testing.T) {
	failure := errors.New("exit")
	runner := &recordingRunner{output: host.Output{Stderr: "details"}, err: failure}
	application := &App{runner: runner, paths: Paths{Home: t.TempDir()}}
	_, err := application.output(context.Background(), "tool", "arg")
	if !errors.Is(err, failure) || err == nil || err.Error() != "tool arg failed: exit: details" {
		t.Fatalf("unexpected error: %v", err)
	}
}
