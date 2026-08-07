package cli

import (
	"context"
	"io"
	"strings"

	"github.com/savioserra/lazyvim/internal/app"
	"github.com/savioserra/lazyvim/internal/buildinfo"
	"github.com/spf13/cobra"
)

type application interface {
	Install(context.Context, app.InstallOptions) error
	Apply(context.Context, []string) error
	Capture(context.Context, []string) error
	Restore(context.Context, app.RestoreOptions) error
	RestoreTmux(context.Context) error
	Check(context.Context) error
	Update(context.Context) error
	Sync(context.Context) error
	SyncContinue(context.Context) error
	LockMason(context.Context) error
	FetchDownloads(context.Context, app.DownloadOptions) error
	VerifyDownloads(bool, bool) error
	ListDownloads(bool, bool) error
	CleanDownloads() error
	LaunchNvim(context.Context, []string) error
}

type applicationFactory func(app.Options) (application, error)

type rootOptions struct {
	repository string
	in         io.Reader
	out        io.Writer
	err        io.Writer
	factory    applicationFactory
}

func New(in io.Reader, out, stderr io.Writer) *cobra.Command {
	return newWithFactory(in, out, stderr, func(options app.Options) (application, error) {
		return app.New(options)
	})
}

func newWithFactory(in io.Reader, out, stderr io.Writer, factory applicationFactory) *cobra.Command {
	options := &rootOptions{in: in, out: out, err: stderr, factory: factory}
	root := &cobra.Command{
		Use:           "lazyvim",
		Short:         "Install and maintain the pinned development environment",
		SilenceUsage:  true,
		SilenceErrors: true,
		Version:       buildinfo.Version(),
	}
	root.SetIn(in)
	root.SetOut(out)
	root.SetErr(stderr)
	root.PersistentFlags().StringVar(&options.repository, "repo", "", "LazyVim repository root (auto-detected by default)")
	root.CompletionOptions.DisableDefaultCmd = true
	root.AddCommand(
		newInstallCommand(options),
		newApplyCommand(options),
		newCaptureCommand(options),
		newRestoreCommand(options),
		newRestoreTmuxCommand(options),
		newCheckCommand(options),
		newUpdateCommand(options),
		newSyncCommand(options),
		newSyncContinueCommand(options),
		newLockMasonCommand(options),
		newDownloadsCommand(options),
		newNvimCommand(options),
	)
	return root
}

func (o *rootOptions) application() (application, error) {
	return o.factory(app.Options{RepoRoot: o.repository, In: o.in, Out: o.out, Err: o.err})
}

func runWithApp(options *rootOptions, action func(context.Context, application) error) func(*cobra.Command, []string) error {
	return runWithAppArgs(options, func(ctx context.Context, application application, _ []string) error {
		return action(ctx, application)
	})
}

func runWithAppArgs(options *rootOptions, action func(context.Context, application, []string) error) func(*cobra.Command, []string) error {
	return func(command *cobra.Command, arguments []string) error {
		application, err := options.application()
		if err != nil {
			return err
		}
		return action(command.Context(), application, arguments)
	}
}

func newInstallCommand(root *rootOptions) *cobra.Command {
	var options app.InstallOptions
	command := &cobra.Command{
		Use:   "install",
		Short: "Install pinned tools and apply managed configuration",
		Args:  cobra.NoArgs,
		RunE: runWithApp(root, func(ctx context.Context, application application) error {
			return application.Install(ctx, options)
		}),
	}
	command.Flags().BoolVar(&options.Minimal, "minimal", false, "install only Neovim, chezmoi, the CLI, and configuration")
	command.Flags().BoolVar(&options.NoFont, "no-font", false, "skip JetBrainsMono Nerd Font")
	command.Flags().BoolVar(&options.NoRestore, "no-restore", false, "skip plugins, Mason packages, and parsers")
	command.Flags().BoolVar(&options.Offline, "offline", false, "forbid network downloads (requires --no-restore)")
	return command
}

func newApplyCommand(root *rootOptions) *cobra.Command {
	return &cobra.Command{
		Use:   "apply [-- chezmoi arguments...]",
		Short: "Apply repository configuration to the home directory",
		Long:  "Apply repository configuration. Put chezmoi flags after -- so Cobra can parse LazyVim flags and help.",
		Args:  cobra.ArbitraryArgs,
		RunE: runWithAppArgs(root, func(ctx context.Context, application application, arguments []string) error {
			return application.Apply(ctx, arguments)
		}),
	}
}

func newCaptureCommand(root *rootOptions) *cobra.Command {
	return &cobra.Command{
		Use:   "capture [-- path...]",
		Short: "Capture modified managed files into the repository",
		Long:  "Capture managed paths. Put path-like values beginning with - after --.",
		Args:  cobra.ArbitraryArgs,
		RunE: runWithAppArgs(root, func(ctx context.Context, application application, arguments []string) error {
			return application.Capture(ctx, arguments)
		}),
	}
}

func newRestoreCommand(root *rootOptions) *cobra.Command {
	var options app.RestoreOptions
	command := &cobra.Command{
		Use:   "restore",
		Short: "Restore plugins, Mason packages, and Tree-sitter parsers",
		Args:  cobra.NoArgs,
		RunE: runWithApp(root, func(ctx context.Context, application application) error {
			return application.Restore(ctx, options)
		}),
	}
	command.Flags().BoolVar(&options.PluginsOnly, "plugins-only", false, "restore Neovim and tmux plugins only")
	command.Flags().BoolVar(&options.MasonOnly, "mason-only", false, "restore Mason packages only")
	command.Flags().BoolVar(&options.SkipParsers, "skip-parsers", false, "do not install missing Tree-sitter parsers")
	return command
}

func newRestoreTmuxCommand(root *rootOptions) *cobra.Command {
	return &cobra.Command{
		Use:   "restore-tmux",
		Short: "Restore tmux plugins to locked commits",
		Args:  cobra.NoArgs,
		RunE: runWithApp(root, func(ctx context.Context, application application) error {
			return application.RestoreTmux(ctx)
		}),
	}
}

func newCheckCommand(root *rootOptions) *cobra.Command {
	return &cobra.Command{
		Use:   "check",
		Short: "Validate tools, locks, configuration, and startup",
		Args:  cobra.NoArgs,
		RunE: runWithApp(root, func(ctx context.Context, application application) error {
			return application.Check(ctx)
		}),
	}
}

func newUpdateCommand(root *rootOptions) *cobra.Command {
	return &cobra.Command{
		Use:   "update",
		Short: "Intentionally update editor locks and parsers",
		Args:  cobra.NoArgs,
		RunE: runWithApp(root, func(ctx context.Context, application application) error {
			return application.Update(ctx)
		}),
	}
}

func newSyncCommand(root *rootOptions) *cobra.Command {
	return &cobra.Command{
		Use:   "sync",
		Short: "Fast-forward the repository and reconcile the host",
		Args:  cobra.NoArgs,
		RunE: runWithApp(root, func(ctx context.Context, application application) error {
			return application.Sync(ctx)
		}),
	}
}

func newSyncContinueCommand(root *rootOptions) *cobra.Command {
	return &cobra.Command{
		Use:    "sync-continue",
		Hidden: true,
		Args:   cobra.NoArgs,
		RunE: runWithApp(root, func(ctx context.Context, application application) error {
			return application.SyncContinue(ctx)
		}),
	}
}

func newLockMasonCommand(root *rootOptions) *cobra.Command {
	return &cobra.Command{
		Use:   "lock-mason",
		Short: "Snapshot installed Mason package versions",
		Args:  cobra.NoArgs,
		RunE: runWithApp(root, func(ctx context.Context, application application) error {
			return application.LockMason(ctx)
		}),
	}
}

func newDownloadsCommand(root *rootOptions) *cobra.Command {
	command := &cobra.Command{Use: "downloads", Short: "Manage verified release archives"}
	var allPlatforms bool
	var includeFont bool

	list := &cobra.Command{
		Use:   "list",
		Short: "List archive sources and cache state",
		Args:  cobra.NoArgs,
		RunE: runWithApp(root, func(_ context.Context, application application) error {
			return application.ListDownloads(allPlatforms, includeFont)
		}),
	}
	list.Flags().BoolVar(&allPlatforms, "all-platforms", false, "include every supported platform")
	list.Flags().BoolVar(&includeFont, "font", false, "include the Nerd Font archive")

	var fetchAll bool
	var fetchFont bool
	fetch := &cobra.Command{
		Use:   "fetch [tool...]",
		Short: "Fetch and verify archives into the download cache",
		Args:  cobra.ArbitraryArgs,
		RunE: runWithAppArgs(root, func(ctx context.Context, application application, arguments []string) error {
			return application.FetchDownloads(ctx, app.DownloadOptions{Names: arguments, AllPlatforms: fetchAll, IncludeFont: fetchFont || contains(arguments, "font")})
		}),
	}
	fetch.Flags().BoolVar(&fetchAll, "all-platforms", false, "fetch every supported platform")
	fetch.Flags().BoolVar(&fetchFont, "font", false, "include the Nerd Font archive")

	var bundleAll bool
	var bundleFont bool
	bundle := &cobra.Command{
		Use:   "bundle [tool...]",
		Short: "Fetch archives into bundles/ for the next go:embed build",
		Args:  cobra.ArbitraryArgs,
		RunE: runWithAppArgs(root, func(ctx context.Context, application application, arguments []string) error {
			return application.FetchDownloads(ctx, app.DownloadOptions{Names: arguments, AllPlatforms: bundleAll, IncludeFont: bundleFont || contains(arguments, "font"), Bundle: true})
		}),
	}
	bundle.Flags().BoolVar(&bundleAll, "all-platforms", false, "bundle every supported platform")
	bundle.Flags().BoolVar(&bundleFont, "font", false, "include the Nerd Font archive")

	var verifyAll bool
	var verifyFont bool
	verify := &cobra.Command{
		Use:   "verify",
		Short: "Verify cached archives against pinned SHA-256 values",
		Args:  cobra.NoArgs,
		RunE: runWithApp(root, func(_ context.Context, application application) error {
			return application.VerifyDownloads(verifyAll, verifyFont)
		}),
	}
	verify.Flags().BoolVar(&verifyAll, "all-platforms", false, "verify every supported platform")
	verify.Flags().BoolVar(&verifyFont, "font", false, "include the Nerd Font archive")

	clean := &cobra.Command{
		Use:   "clean",
		Short: "Remove the download cache",
		Args:  cobra.NoArgs,
		RunE: runWithApp(root, func(_ context.Context, application application) error {
			return application.CleanDownloads()
		}),
	}
	command.AddCommand(list, fetch, bundle, verify, clean)
	return command
}

func newNvimCommand(root *rootOptions) *cobra.Command {
	return &cobra.Command{
		Use:   "nvim [-- arguments...]",
		Short: "Run the pinned Neovim with normalized environment",
		Long:  "Run pinned Neovim. Put Neovim flags after -- so Cobra can parse LazyVim flags and help.",
		Args:  cobra.ArbitraryArgs,
		RunE: runWithAppArgs(root, func(ctx context.Context, application application, arguments []string) error {
			return application.LaunchNvim(ctx, arguments)
		}),
	}
}

func contains(values []string, expected string) bool {
	for _, value := range values {
		if strings.EqualFold(value, expected) {
			return true
		}
	}
	return false
}

func ExecuteContext(ctx context.Context, root *cobra.Command) error {
	return root.ExecuteContext(ctx)
}
