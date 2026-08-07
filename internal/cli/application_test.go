package cli

import (
	"context"
	"io"
	"reflect"
	"testing"

	"github.com/savioserra/lazyvim/internal/app"
)

type testApplication struct {
	context context.Context
	apply   []string
}

func (a *testApplication) Install(context.Context, app.InstallOptions) error { return nil }
func (a *testApplication) Apply(ctx context.Context, arguments []string) error {
	a.context, a.apply = ctx, arguments
	return nil
}
func (a *testApplication) Capture(context.Context, []string) error                   { return nil }
func (a *testApplication) Restore(context.Context, app.RestoreOptions) error         { return nil }
func (a *testApplication) RestoreTmux(context.Context) error                         { return nil }
func (a *testApplication) Check(ctx context.Context) error                           { a.context = ctx; return nil }
func (a *testApplication) Update(context.Context) error                              { return nil }
func (a *testApplication) Sync(context.Context) error                                { return nil }
func (a *testApplication) SyncContinue(context.Context) error                        { return nil }
func (a *testApplication) LockMason(context.Context) error                           { return nil }
func (a *testApplication) FetchDownloads(context.Context, app.DownloadOptions) error { return nil }
func (a *testApplication) VerifyDownloads(bool, bool) error                          { return nil }
func (a *testApplication) ListDownloads(bool, bool) error                            { return nil }
func (a *testApplication) CleanDownloads() error                                     { return nil }
func (a *testApplication) LaunchNvim(context.Context, []string) error                { return nil }

func TestCommandContextReachesApplication(t *testing.T) {
	record := &testApplication{}
	root := newWithFactory(nil, io.Discard, io.Discard, func(app.Options) (application, error) {
		return record, nil
	})
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	root.SetArgs([]string{"check"})
	if err := root.ExecuteContext(ctx); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(record.context, ctx) || record.context.Err() != context.Canceled {
		t.Fatalf("application did not receive canceled command context")
	}
}

func TestPassThroughUsesDelimiterAndParsesPersistentFlags(t *testing.T) {
	record := &testApplication{}
	var options app.Options
	root := newWithFactory(nil, io.Discard, io.Discard, func(got app.Options) (application, error) {
		options = got
		return record, nil
	})
	root.SetArgs([]string{"apply", "--repo", "/trusted/repository", "--", "--dry-run"})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	if options.RepoRoot != "/trusted/repository" {
		t.Fatalf("got repository %q", options.RepoRoot)
	}
	if !reflect.DeepEqual(record.apply, []string{"--dry-run"}) {
		t.Fatalf("forwarded arguments: %#v", record.apply)
	}
}

func TestPassThroughHelpDoesNotConstructApplication(t *testing.T) {
	called := false
	root := newWithFactory(nil, io.Discard, io.Discard, func(app.Options) (application, error) {
		called = true
		return &testApplication{}, nil
	})
	root.SetArgs([]string{"apply", "--help"})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	if called {
		t.Fatal("help constructed the application")
	}
}
