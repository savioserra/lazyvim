package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"

	"github.com/savioserra/lazyvim/internal/app"
	"github.com/savioserra/lazyvim/internal/cli"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), terminationSignals()...)
	defer stop()
	name := strings.TrimSuffix(strings.ToLower(filepath.Base(os.Args[0])), ".exe")
	var err error
	if name == "nvim" {
		application, appErr := app.New(app.Options{})
		if appErr != nil {
			err = appErr
		} else {
			err = application.LaunchNvim(ctx, os.Args[1:])
		}
	} else {
		err = cli.ExecuteContext(ctx, cli.New(os.Stdin, os.Stdout, os.Stderr))
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}
