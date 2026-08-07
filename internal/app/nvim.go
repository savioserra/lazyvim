package app

import (
	"context"
	"os"
)

func (a *App) LaunchNvim(ctx context.Context, arguments []string) error {
	nvim, err := a.nvimPath()
	if err != nil {
		return err
	}
	environment := a.commandEnvironment(nvim)
	return replaceProcess(ctx, nvim, append([]string{nvim}, arguments...), environment, a.in, a.out, a.err)
}

func CurrentExecutableName() string {
	return os.Args[0]
}
