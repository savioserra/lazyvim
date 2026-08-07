package app

import (
	"context"
	"io"
	"os"

	"github.com/savioserra/lazyvim/internal/download"
	"github.com/savioserra/lazyvim/internal/host"
)

type fakeDownloader struct {
	path    string
	fetched []download.Artifact
	offline bool
}

func (d *fakeDownloader) Fetch(_ context.Context, artifact download.Artifact, _ string) (string, error) {
	d.fetched = append(d.fetched, artifact)
	return d.path, nil
}

func (d *fakeDownloader) SetOffline(offline bool) { d.offline = offline }

type noopRunner struct{}

func (noopRunner) Run(context.Context, host.Command) error { return nil }
func (noopRunner) Output(context.Context, host.Command) (host.Output, error) {
	return host.Output{}, nil
}

func discardApp() *App {
	return &App{in: nil, out: io.Discard, err: io.Discard, runner: noopRunner{}}
}

func mustWriteFile(t interface{ Fatal(...any) }, path string, content []byte, mode os.FileMode) {
	if err := os.WriteFile(path, content, mode); err != nil {
		t.Fatal(err)
	}
}
