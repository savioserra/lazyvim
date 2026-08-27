package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/config"
	"github.com/savioserra/lazyvim/services/subagents/internal/remoting"
	"github.com/savioserra/lazyvim/services/subagents/internal/service"
	workstationsocket "github.com/savioserra/lazyvim/services/subagents/internal/socket"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	paths, err := workstationsocket.ResolvePaths()
	if err != nil {
		return err
	}
	configPath := flag.String("config", paths.ConfigFile, "owner-private service configuration")
	socketPath := flag.String("socket", paths.SocketFile, "owner-private Unix socket")
	flag.Parse()
	resolvedConfig, resolvedSocket, err := normalizeCLIPaths(*configPath, *socketPath, workstationsocket.NormalizePrivatePath)
	if err != nil {
		return err
	}

	cfg, err := config.Load(resolvedConfig)
	if err != nil {
		return err
	}
	if !cfg.Service.Enabled {
		return errors.New("service is inactive; set service.enabled explicitly in private configuration")
	}
	if err := workstationsocket.EnsurePrivateDir(paths.StateDir); err != nil {
		return fmt.Errorf("prepare XDG state directory: %w", err)
	}
	// GoAkt v4.5.2 native TLS cannot bind an authenticated peer identity to
	// the configured inbound CIDR policy. Validation therefore fails closed
	// when remoting is enabled and never installs actor.WithRemote.
	_, _, err = remoting.NewValidatedConfig(cfg.Remoting, config.NewNetworkResolver(), config.InterfaceAddressSource{})
	if err != nil {
		return fmt.Errorf("validate remoting: %w", err)
	}

	ctx, stopSignals := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopSignals()
	hosted := service.HostedAdminConfig{Enabled: cfg.HostedPi.Enabled, TmuxBinary: cfg.HostedPi.TmuxBinary, PiBinary: cfg.HostedPi.PiBinary, BridgeExtension: cfg.HostedPi.BridgeExtension, ServerName: cfg.HostedPi.TmuxServerName, TmuxConfig: cfg.HostedPi.TmuxConfig, StateDirectory: cfg.HostedPi.StateDirectory, PiSessionDirectory: cfg.HostedPi.PiSessionDirectory, CredentialDirectory: cfg.HostedPi.CredentialDirectory, AdminCredentialFile: cfg.HostedPi.AdminCredentialFile, DefaultProjectDirectory: cfg.HostedPi.DefaultProjectDirectory, TrustProject: cfg.HostedPi.TrustProject}
	daemon, err := service.StartConfigured(ctx, resolvedSocket, hosted)
	if err != nil {
		return err
	}
	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return daemon.Stop(shutdownCtx)
}

func normalizeCLIPaths(configPath, socketPath string, normalize func(string) (string, error)) (string, string, error) {
	resolvedConfig, err := normalize(configPath)
	if err != nil {
		return "", "", fmt.Errorf("resolve config path: %w", err)
	}
	resolvedSocket, err := normalize(socketPath)
	if err != nil {
		return "", "", fmt.Errorf("resolve socket path: %w", err)
	}
	return resolvedConfig, resolvedSocket, nil
}
