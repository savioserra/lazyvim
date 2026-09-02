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
	flag.Parse()
	resolvedConfig, err := workstationsocket.NormalizePrivatePath(*configPath)
	if err != nil {
		return fmt.Errorf("resolve config path: %w", err)
	}

	cfg, err := config.Load(resolvedConfig)
	if err != nil {
		return err
	}
	if !cfg.Service.Enabled {
		return errors.New("service is inactive; set service.enabled explicitly in private configuration")
	}
	if err := workstationsocket.EnsureOwnedPrivateDir(paths.StateDir); err != nil {
		return fmt.Errorf("prepare XDG state directory: %w", err)
	}
	// The actor plane binds only the concrete local trusted-network address.
	// Configured DNS supplies bootstrap addresses; network identity and URI-SAN
	// mTLS are independent, conjunctive trust boundaries.
	actorPlane, _, err := remoting.NewValidatedConfig(cfg.Remoting, config.NewNetworkResolver(), config.InterfaceAddressSource{})
	if err != nil {
		return fmt.Errorf("validate remoting: %w", err)
	}

	ctx, stopSignals := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stopSignals()
	hosted := service.HostedAdminConfig{Enabled: cfg.HostedPi.Enabled, TmuxBinary: cfg.HostedPi.TmuxBinary, PiBinary: cfg.HostedPi.PiBinary, BridgeExtension: cfg.HostedPi.BridgeExtension, ServerName: cfg.HostedPi.TmuxServerName, TmuxConfig: cfg.HostedPi.TmuxConfig, StateDirectory: cfg.HostedPi.StateDirectory, PiSessionDirectory: cfg.HostedPi.PiSessionDirectory, CredentialDirectory: cfg.HostedPi.CredentialDirectory, AdminCredentialFile: cfg.HostedPi.AdminCredentialFile, DefaultProjectDirectory: cfg.HostedPi.DefaultProjectDirectory, IntrospectionModel: cfg.HostedPi.IntrospectionModel, TrustProject: cfg.HostedPi.TrustProject}
	actorHost := "127.0.0.1"
	if actorPlane != nil && actorPlane.NodeIdentity != "" {
		if node, ok := actorPlane.PublicNodes[actorPlane.NodeIdentity]; ok && node.Host != "" {
			actorHost = node.Host
		}
	}
	actorPort := cfg.Service.ActorEndpointPort
	if actorPort == 0 {
		actorPort = 17213
	}
	listenAddress := fmt.Sprintf("%s:%d", actorHost, actorPort)
	hosted.ActorEndpoint = fmt.Sprintf("ws://%s/actors", listenAddress)
	daemon, err := service.StartWebSocketConfigured(ctx, listenAddress, hosted, actorPlane)
	if err != nil {
		return err
	}
	<-ctx.Done()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return daemon.Stop(shutdownCtx)
}
