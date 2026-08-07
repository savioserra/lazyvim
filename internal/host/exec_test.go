package host

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"strings"
	"testing"
)

func TestExecRunnerCapturesOutput(t *testing.T) {
	runner := ExecRunner{}
	result, err := runner.Output(context.Background(), helperCommand("success"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(result.Stdout) != "stdout" || strings.TrimSpace(result.Stderr) != "stderr" {
		t.Fatalf("unexpected output: %+v", result)
	}
}

func TestExecRunnerStreamsAndReturnsFailure(t *testing.T) {
	runner := ExecRunner{}
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	command := helperCommand("failure")
	command.Out = &stdout
	command.Err = &stderr
	err := runner.Run(context.Background(), command)
	if err == nil {
		t.Fatal("expected helper failure")
	}
	if strings.TrimSpace(stdout.String()) != "stdout" || strings.TrimSpace(stderr.String()) != "stderr" {
		t.Fatalf("unexpected streams: stdout=%q stderr=%q", stdout.String(), stderr.String())
	}
}

func helperCommand(mode string) Command {
	return Command{
		Name: os.Args[0],
		Args: []string{"-test.run=TestExecRunnerHelperProcess", "--", mode},
		Env:  append(os.Environ(), "GO_WANT_HOST_HELPER=1"),
	}
}

func TestExecRunnerHelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_HOST_HELPER") != "1" {
		return
	}
	fmt.Fprintln(os.Stdout, "stdout")
	fmt.Fprintln(os.Stderr, "stderr")
	for index, argument := range os.Args {
		if argument == "--" && index+1 < len(os.Args) && os.Args[index+1] == "failure" {
			os.Exit(7)
		}
	}
	os.Exit(0)
}

func TestExecRunnerHonorsCanceledContext(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := (ExecRunner{}).Output(ctx, helperCommand("success"))
	if err == nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v, want context cancellation", err)
	}
}
