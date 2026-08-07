package app

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/internal/config"
	"github.com/savioserra/lazyvim/internal/host"
)

type commandListRunner struct {
	commands []host.Command
}

func (r *commandListRunner) Run(_ context.Context, command host.Command) error {
	r.commands = append(r.commands, command)
	return nil
}

func (r *commandListRunner) Output(_ context.Context, command host.Command) (host.Output, error) {
	r.commands = append(r.commands, command)
	return host.Output{}, nil
}

func TestFirstApplyBacksUpTargetsAndForcesNonInteractiveReplacement(t *testing.T) {
	home := t.TempDir()
	state := filepath.Join(home, "state")
	managed := filepath.Join(home, ".config", "nvim")
	if err := os.MkdirAll(managed, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(managed, "init.lua"), []byte("existing"), 0o600); err != nil {
		t.Fatal(err)
	}
	opt := filepath.Join(home, "opt")
	chezmoi := filepath.Join(opt, "chezmoi", "chezmoi")
	if err := os.MkdirAll(filepath.Dir(chezmoi), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(chezmoi, []byte("binary"), 0o700); err != nil {
		t.Fatal(err)
	}
	runner := &commandListRunner{}
	application := &App{
		repoRoot: "/repository",
		paths: Paths{
			Home:       home,
			State:      state,
			Opt:        opt,
			NvimConfig: managed,
		},
		platform: config.Platform{GOOS: "linux"},
		catalog: config.Catalog{Releases: []config.Release{{
			Name: "chezmoi", TargetName: "chezmoi", ExpectedBinary: "chezmoi",
		}}},
		out:    io.Discard,
		err:    io.Discard,
		now:    func() time.Time { return time.Unix(0, 0).UTC() },
		runner: runner,
	}
	if err := application.migrateAndApply(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(runner.commands) == 0 {
		t.Fatal("chezmoi was not invoked")
	}
	arguments := runner.commands[0].Args
	if len(arguments) < 2 || arguments[len(arguments)-2] != "apply" || arguments[len(arguments)-1] != "--force" {
		t.Fatalf("first apply was not forced: %v", arguments)
	}
	if !regularFile(filepath.Join(state, "chezmoi-source-state-v1")) {
		t.Fatal("migration marker was not written")
	}
	if !regularFile(filepath.Join(application.backupRoot, ".config", "nvim", "init.lua")) {
		t.Fatal("existing configuration was not backed up")
	}
}
