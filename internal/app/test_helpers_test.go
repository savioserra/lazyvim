package app

import (
	"context"
	"io"
	"os"

	"github.com/savioserra/lazyvim/internal/download"
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

func discardApp() *App {
	return &App{in: nil, out: io.Discard, err: io.Discard}
}

func mustWriteFile(t interface{ Fatal(...any) }, path string, content []byte, mode os.FileMode) {
	if err := os.WriteFile(path, content, mode); err != nil {
		t.Fatal(err)
	}
}
