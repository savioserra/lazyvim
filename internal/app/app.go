package app

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	dotfiles "github.com/savioserra/lazyvim"
	"github.com/savioserra/lazyvim/internal/config"
	"github.com/savioserra/lazyvim/internal/download"
	"github.com/savioserra/lazyvim/internal/host"
)

type ArtifactDownloader interface {
	Fetch(context.Context, download.Artifact, string) (string, error)
	SetOffline(bool)
}

type Options struct {
	RepoRoot   string
	In         io.Reader
	Out        io.Writer
	Err        io.Writer
	Platform   *config.Platform
	Paths      *Paths
	Embedded   fs.FS
	Downloader ArtifactDownloader
	Now        func() time.Time
	Executable func() (string, error)
	Runner     host.Runner
	CopyFile   func(string, string, os.FileMode) error
}

type Paths = host.Paths

type App struct {
	repoRoot       string
	actualRepo     bool
	paths          Paths
	platform       config.Platform
	tools          config.Values
	catalog        config.Catalog
	embedded       fs.FS
	downloader     ArtifactDownloader
	in             io.Reader
	out            io.Writer
	err            io.Writer
	now            func() time.Time
	executablePath func() (string, error)
	runner         host.Runner
	copyFile       func(string, string, os.FileMode) error
	backupRoot     string
}

func New(options Options) (*App, error) {
	if options.In == nil {
		options.In = os.Stdin
	}
	if options.Out == nil {
		options.Out = os.Stdout
	}
	if options.Err == nil {
		options.Err = os.Stderr
	}
	var platform config.Platform
	if options.Platform != nil {
		platform = *options.Platform
	} else {
		var err error
		platform, err = config.CurrentPlatform()
		if err != nil {
			return nil, err
		}
	}
	var paths Paths
	if options.Paths != nil {
		paths = *options.Paths
	} else {
		var err error
		paths, err = host.ResolvePaths(platform)
		if err != nil {
			return nil, err
		}
	}
	embedded := options.Embedded
	if embedded == nil {
		embedded = dotfiles.Embedded
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	if options.Executable == nil {
		options.Executable = os.Executable
	}
	if options.Runner == nil {
		options.Runner = host.ExecRunner{}
	}
	if options.CopyFile == nil {
		options.CopyFile = copyFile
	}
	repository, actual, err := resolveRepository(options.RepoRoot, paths.State)
	if err != nil {
		return nil, err
	}
	if repository == "" {
		repository, err = materializeEmbeddedSourceFrom(embedded, paths.State)
		if err != nil {
			return nil, err
		}
	}

	manifest, err := openManifest(embedded, repository, actual)
	if err != nil {
		return nil, err
	}
	defer manifest.Close()
	tools, err := config.Parse(manifest)
	if err != nil {
		return nil, err
	}
	catalog, err := config.NewCatalog(tools, platform)
	if err != nil {
		return nil, err
	}

	application := &App{
		repoRoot:       repository,
		actualRepo:     actual,
		paths:          paths,
		platform:       platform,
		tools:          tools,
		catalog:        catalog,
		embedded:       embedded,
		in:             options.In,
		out:            options.Out,
		err:            options.Err,
		now:            options.Now,
		executablePath: options.Executable,
		runner:         options.Runner,
		copyFile:       options.CopyFile,
	}
	application.downloader = options.Downloader
	if application.downloader == nil {
		application.downloader = download.New(embedded, application.logf)
	}
	return application, nil
}

func (a *App) logf(format string, arguments ...any) {
	fmt.Fprintf(a.out, "==> "+format+"\n", arguments...)
}

func (a *App) warnf(format string, arguments ...any) {
	fmt.Fprintf(a.err, "warning: "+format+"\n", arguments...)
}

func (a *App) run(ctx context.Context, name string, arguments ...string) error {
	return a.runIn(ctx, "", name, arguments...)
}

func (a *App) runIn(ctx context.Context, directory, name string, arguments ...string) error {
	return a.runInWithEnvironment(ctx, directory, nil, name, arguments...)
}

func (a *App) runWithEnvironment(ctx context.Context, environment []string, name string, arguments ...string) error {
	return a.runInWithEnvironment(ctx, "", environment, name, arguments...)
}

func (a *App) runInWithEnvironment(ctx context.Context, directory string, environment []string, name string, arguments ...string) error {
	command := host.Command{
		Name: name,
		Args: arguments,
		Dir:  directory,
		Env:  environmentOverrides(a.commandEnvironment(name), environment),
		In:   a.in,
		Out:  a.out,
		Err:  a.err,
	}
	if err := a.runner.Run(ctx, command); err != nil {
		return commandError(name, arguments, err, "")
	}
	return nil
}

func (a *App) output(ctx context.Context, name string, arguments ...string) (string, error) {
	result, err := a.runner.Output(ctx, host.Command{Name: name, Args: arguments, Env: a.commandEnvironment(name)})
	if err != nil {
		return "", commandError(name, arguments, err, result.Stderr)
	}
	return strings.TrimSpace(result.Stdout), nil
}

func (a *App) commandEnvironment(name string) []string {
	environment := os.Environ()
	if filepath.Base(name) != "nvim" && filepath.Base(name) != "nvim.exe" {
		return environment
	}
	data := os.Getenv("XDG_DATA_HOME")
	if host.NormalizedDataHome(a.paths.Home, data) == data {
		return environment
	}
	filtered := environment[:0]
	for _, entry := range environment {
		if !strings.HasPrefix(entry, "XDG_DATA_HOME=") {
			filtered = append(filtered, entry)
		}
	}
	return filtered
}

func environmentOverrides(baseEnvironment, overrides []string) []string {
	for _, override := range overrides {
		name, _, _ := strings.Cut(override, "=")
		filtered := baseEnvironment[:0]
		for _, entry := range baseEnvironment {
			if !strings.HasPrefix(entry, name+"=") {
				filtered = append(filtered, entry)
			}
		}
		baseEnvironment = append(filtered, override)
	}
	return baseEnvironment
}

func commandError(name string, arguments []string, err error, stderr string) error {
	detail := strings.TrimSpace(stderr)
	if detail != "" {
		return fmt.Errorf("%s %s failed: %w: %s", name, strings.Join(arguments, " "), err, detail)
	}
	return fmt.Errorf("%s %s failed: %w", name, strings.Join(arguments, " "), err)
}

func (a *App) executable(release config.Release) string {
	return filepath.Join(a.paths.Opt, release.TargetName, filepath.FromSlash(release.ExpectedBinary))
}

func (a *App) nvimPath() (string, error) {
	release, ok := a.catalog.Release("nvim")
	if !ok {
		return "", errors.New("Neovim is missing from tool catalog")
	}
	path := host.EnvironmentOr("NVIM_BIN", a.executable(release))
	if !executableFile(path) {
		return "", fmt.Errorf("pinned Neovim is not installed or executable: %s; run dotfiles install first", path)
	}
	return path, nil
}

func (a *App) chezmoiPath() (string, error) {
	release, ok := a.catalog.Release("chezmoi")
	if !ok {
		return "", errors.New("chezmoi is missing from tool catalog")
	}
	path := host.EnvironmentOr("CHEZMOI_BIN", a.executable(release))
	if !executableFile(path) {
		return "", fmt.Errorf("pinned chezmoi is not installed or executable: %s; run dotfiles install first", path)
	}
	return path, nil
}

func (a *App) backupDirectory() string {
	if a.backupRoot == "" {
		a.backupRoot = filepath.Join(a.paths.State, "backups", fmt.Sprintf("%s-%d", a.now().UTC().Format("20060102T150405Z"), os.Getpid()))
	}
	return a.backupRoot
}

func pathExists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func regularFile(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.Mode().IsRegular()
}

func executableFile(path string) bool {
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return false
	}
	return runtime.GOOS == "windows" || info.Mode().Perm()&0o111 != 0
}

func directory(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func runtimeExecutableExtension() string {
	if runtime.GOOS == "windows" {
		return ".exe"
	}
	return ""
}
