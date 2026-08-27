package service

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/hostedpi"
)

type compensationProcess struct {
	binding   application.HostedPiRuntimeBinding
	done      chan error
	once      sync.Once
	stopped   chan struct{}
	stopDelay time.Duration
	stopErr   error
}

func (p *compensationProcess) Binding() application.HostedPiRuntimeBinding { return p.binding }
func (p *compensationProcess) Wait() error                                 { return <-p.done }
func (p *compensationProcess) Stop(context.Context) error {
	p.once.Do(func() {
		close(p.stopped)
		if p.stopDelay > 0 {
			time.Sleep(p.stopDelay)
		}
		if p.stopErr == nil {
			p.done <- nil
		}
	})
	return p.stopErr
}

type compensationRuntime struct {
	started   chan *compensationProcess
	stopDelay time.Duration
	stopErr   error
}

func (r compensationRuntime) Start(_ context.Context, spec application.HostedPiLaunchSpec) (application.HostedPiOwnedProcess, error) {
	p := &compensationProcess{binding: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStarting, RuntimeID: spec.RuntimeID, Incarnation: spec.Incarnation, TmuxSession: spec.TmuxSession, TmuxSessionID: "$compensated", TmuxWindowID: "@compensated", TmuxPane: "%compensated"}, done: make(chan error, 1), stopped: make(chan struct{}), stopDelay: r.stopDelay, stopErr: r.stopErr}
	r.started <- p
	return p, nil
}

func delayedRegistryService(t *testing.T, hosted HostedAdminConfig) *Service {
	return delayedRegistryServiceWithDelay(t, hosted, 100*time.Millisecond)
}
func delayedRegistryServiceWithDelay(t *testing.T, hosted HostedAdminConfig, delay time.Duration) *Service {
	t.Helper()
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", filepath.Join(root, "daemon.sock"))
	if err != nil {
		t.Fatal(err)
	}
	value, err := startWithListener(context.Background(), listener, hosted, listener.Addr().String(), registryTestDelay(delay))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = value.Stop(ctx)
	})
	value.registrationTimeout = 30 * time.Millisecond
	return value
}

func hostedRegistrationForCompensation(runtime application.HostedPiRuntime) application.RegisterAgent {
	binding := application.InactiveHostedPiRuntimeBinding()
	binding.State, binding.RuntimeID, binding.Incarnation = application.HostedPiRuntimeStarting, "compensated-runtime", 1
	return application.RegisterAgent{AgentID: "compensated-agent", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: binding.RuntimeID}, HostedPiRuntime: binding, AllowedCapability: []string{"observe", "hosted_bridge"}, PhaseTwoOwned: true, Retention: "explicit", Recovery: "owned-binding-v1", Runtime: runtime, LaunchSpec: application.HostedPiLaunchSpec{AgentID: "compensated-agent", RuntimeID: binding.RuntimeID, Incarnation: 1, TmuxSession: "compensated", TmuxWindow: "pi", PiSessionDirectory: "/tmp/compensated", PiSessionName: "compensated"}, RuntimeStartTimeout: time.Second}
}

func TestDelayedRegistrationTimeoutCompensatesRuntimeBeforeRetry(t *testing.T) {
	started := make(chan *compensationProcess, 2)
	daemon := delayedRegistryService(t, HostedAdminConfig{})
	err := daemon.RegisterAgent(context.Background(), hostedRegistrationForCompensation(compensationRuntime{started: started}))
	if err == nil {
		t.Fatal("delayed registration did not time out")
	}
	var process *compensationProcess
	select {
	case process = <-started:
	case <-time.After(time.Second):
		t.Fatal("delayed runtime never started")
	}
	select {
	case <-process.stopped:
	case <-time.After(time.Second):
		t.Fatal("registration compensation did not stop runtime")
	}
	daemon.registrationTimeout = 500 * time.Millisecond
	observed := application.RegisterAgent{AgentID: "compensated-agent", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "retry"}, HostedPiRuntime: application.InactiveHostedPiRuntimeBinding(), AllowedCapability: []string{"observe"}, Retention: "explicit", Recovery: "metadata-only"}
	if err := daemon.RegisterAgent(context.Background(), observed); err != nil {
		t.Fatalf("retry found delayed child still registered: %v", err)
	}
}

func TestEightSecondDelayedRegistrationOutcomeRemainsTrackedForPublicHostedAndShutdown(t *testing.T) {
	root := t.TempDir()
	_ = os.Chmod(root, 0o700)
	started := make(chan *compensationProcess, 2)
	hosted := HostedAdminConfig{StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), DefaultProjectDirectory: root, TrustProject: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge", RuntimeFactory: func(hostedpi.Config) application.HostedPiRuntime { return compensationRuntime{started: started} }}
	daemon := delayedRegistryServiceWithDelay(t, hosted, 8200*time.Millisecond)
	began := time.Now()
	if err := daemon.RegisterAgent(context.Background(), hostedRegistrationForCompensation(compensationRuntime{started: started})); err == nil {
		t.Fatal("public delayed registration did not return timeout")
	}
	if _, err := daemon.startHostedAgent(context.Background(), &subagentsv1.HostedAdminRequest{AgentId: "hosted-eight-second", ProjectDirectory: root, TrustProject: true}); err == nil {
		t.Fatal("hosted delayed registration did not return timeout")
	}
	if time.Since(began) > time.Second {
		t.Fatal("foreground calls waited for delayed PID publication")
	}
	daemon.hostedMu.Lock()
	placeholders := len(daemon.registrationPlaceholders)
	daemon.hostedMu.Unlock()
	if placeholders != 2 {
		t.Fatalf("pre-enqueue placeholders missing: %d", placeholders)
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	if err := daemon.Stop(shutdownCtx); err != nil {
		t.Fatalf("daemon stopped before delayed registration reconciliation: %v", err)
	}
	for index := 0; index < 2; index++ {
		process := <-started
		select {
		case <-process.stopped:
		default:
			t.Fatal("delayed created runtime was orphaned")
		}
	}
	daemon.hostedMu.Lock()
	remainingPlaceholders, remainingCleanups := len(daemon.registrationPlaceholders), len(daemon.registrationCleanups)
	daemon.hostedMu.Unlock()
	if remainingPlaceholders != 0 || remainingCleanups != 0 {
		t.Fatalf("registration reconciliation remained: placeholders=%d cleanups=%d", remainingPlaceholders, remainingCleanups)
	}
	if files, _ := filepath.Glob(filepath.Join(root, "credentials", "*.json")); len(files) != 0 {
		t.Fatalf("hosted delayed registration leaked credential: %v", files)
	}
}

func TestDelayedRejectedHostedRegistrationCleansMetadataAndAllowsRetry(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	hosted := HostedAdminConfig{StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), DefaultProjectDirectory: root, TrustProject: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge"}
	daemon := delayedRegistryService(t, hosted)
	daemon.registrationTimeout = 500 * time.Millisecond
	existing := application.RegisterAgent{AgentID: "delayed-duplicate", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "existing"}, HostedPiRuntime: application.InactiveHostedPiRuntimeBinding(), AllowedCapability: []string{"observe"}, Retention: "explicit", Recovery: "metadata-only"}
	if err := daemon.RegisterAgent(context.Background(), existing); err != nil {
		t.Fatal(err)
	}

	closed := make(chan string, 2)
	actualClose := daemon.closeHostedSession
	daemon.closeHostedSession = func(ctx context.Context, id string) error {
		closed <- id
		return actualClose(ctx, id)
	}
	daemon.registrationTimeout = 30 * time.Millisecond
	command := &subagentsv1.HostedAdminRequest{AgentId: existing.AgentID, ProjectDirectory: root, TrustProject: true}
	if _, err := daemon.startHostedAgent(context.Background(), command); err == nil {
		t.Fatal("delayed duplicate registration did not fail")
	}
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("delayed non-created registration did not close its hosted session")
	}
	deadline := time.Now().Add(time.Second)
	for {
		files, _ := filepath.Glob(filepath.Join(root, "credentials", "*.json"))
		daemon.hostedMu.Lock()
		pending := len(daemon.registrationPlaceholders) + len(daemon.registrationCleanups)
		daemon.hostedMu.Unlock()
		if len(files) == 0 && pending == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("delayed non-created metadata remained: files=%v pending=%d", files, pending)
		}
		time.Sleep(10 * time.Millisecond)
	}

	if _, err := daemon.startHostedAgent(context.Background(), command); err == nil || strings.Contains(err.Error(), "file exists") {
		t.Fatalf("retry did not recreate and clean the credential normally: %v", err)
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := daemon.Stop(shutdownCtx); err != nil {
		t.Fatalf("daemon stop did not finish delayed non-created cleanup: %v", err)
	}
}

func TestRegistrationCompensationPublishesPIDBeforeEightSecondTeardownAndAllowsNameRetry(t *testing.T) {
	started := make(chan *compensationProcess, 1)
	daemon := delayedRegistryService(t, HostedAdminConfig{})
	began := time.Now()
	if err := daemon.RegisterAgent(context.Background(), hostedRegistrationForCompensation(compensationRuntime{started: started, stopDelay: 8 * time.Second})); err == nil {
		t.Fatal("delayed registration did not time out")
	}
	if time.Since(began) > time.Second {
		t.Fatal("registration timeout waited for long child teardown instead of publishing PID")
	}
	deadline := time.Now().Add(time.Second)
	tracked := false
	for time.Now().Before(deadline) {
		daemon.hostedMu.Lock()
		tracked = len(daemon.registrationCleanups) == 1
		daemon.hostedMu.Unlock()
		if tracked {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !tracked {
		t.Fatal("created PID was not tracked for asynchronous cleanup")
	}
	daemon.registrationTimeout = 500 * time.Millisecond
	observed := application.RegisterAgent{AgentID: "compensated-agent", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "retry"}, HostedPiRuntime: application.InactiveHostedPiRuntimeBinding(), AllowedCapability: []string{"observe"}, Retention: "explicit", Recovery: "metadata-only"}
	if err := daemon.RegisterAgent(context.Background(), observed); err != nil {
		t.Fatalf("actor-name retry was blocked by retiring child: %v", err)
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	if err := daemon.Stop(shutdownCtx); err != nil {
		t.Fatalf("daemon did not track long registration cleanup through shutdown: %v", err)
	}
	daemon.hostedMu.Lock()
	remaining := len(daemon.registrationCleanups)
	daemon.hostedMu.Unlock()
	if remaining != 0 {
		t.Fatal("long registration cleanup remained after shutdown")
	}
}

func TestLateRegistrationTeardownFailureRemainsTracked(t *testing.T) {
	started := make(chan *compensationProcess, 1)
	daemon := delayedRegistryService(t, HostedAdminConfig{})
	if err := daemon.RegisterAgent(context.Background(), hostedRegistrationForCompensation(compensationRuntime{started: started, stopErr: errors.New("late teardown failure")})); err == nil {
		t.Fatal("registration did not time out")
	}
	process := <-started
	time.Sleep(100 * time.Millisecond)
	daemon.hostedMu.Lock()
	remaining := len(daemon.registrationCleanups)
	var cleanup *registrationCleanup
	for _, item := range daemon.registrationCleanups {
		cleanup = item
	}
	daemon.hostedMu.Unlock()
	if remaining != 1 {
		t.Fatal("late teardown failure lost created PID tracking")
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	if err := daemon.Stop(shutdownCtx); err == nil {
		t.Fatal("daemon shutdown hid unproven teardown failure")
	}
	// Inject the later external death proof and verify retry completes without
	// losing the retired PID in between attempts.
	process.done <- nil
	cleanup.mu.Lock()
	cleanup.runtimeStopped = true
	cleanup.mu.Unlock()
	retryCtx, retryCancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer retryCancel()
	if err := daemon.Stop(retryCtx); err != nil {
		t.Fatalf("daemon shutdown retry did not consume late proof: %v", err)
	}
}

func TestStoppedCleanupPendingRetriesWithoutDeadRuntimeCalls(t *testing.T) {
	root := t.TempDir()
	_ = os.Chmod(root, 0o700)
	started := make(chan *compensationProcess, 2)
	hosted := HostedAdminConfig{StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), DefaultProjectDirectory: root, TrustProject: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge", RuntimeFactory: func(hostedpi.Config) application.HostedPiRuntime { return compensationRuntime{started: started} }}
	daemon := delayedRegistryService(t, hosted)
	daemon.registrationTimeout = 500 * time.Millisecond
	command := &subagentsv1.HostedAdminRequest{AgentId: "cleanup-retry", ProjectDirectory: root, TrustProject: true}
	if _, err := daemon.startHostedAgent(context.Background(), command); err != nil {
		t.Fatal(err)
	}
	process := <-started
	actualClose := daemon.closeHostedSession
	failed := false
	daemon.closeHostedSession = func(ctx context.Context, id string) error {
		if !failed {
			failed = true
			return errors.New("injected close failure")
		}
		return actualClose(ctx, id)
	}
	if _, err := daemon.stopHostedAgent(context.Background(), command.AgentId); err == nil {
		t.Fatal("injected close failure was ignored")
	}
	daemon.hostedMu.Lock()
	_, live := daemon.hostedRuntimes[command.AgentId]
	_, pending := daemon.hostedCleanup[command.AgentId]
	terminal := daemon.hostedTerminal[command.AgentId]
	daemon.hostedMu.Unlock()
	if live || !pending || terminal.State != application.HostedPiRuntimeStopped || !terminal.CleanupPending {
		t.Fatalf("stopped runtime was not atomically retired: live=%v pending=%v terminal=%#v", live, pending, terminal)
	}
	select {
	case <-process.stopped:
	default:
		t.Fatal("runtime was not stopped before cleanup became pending")
	}
	if _, err := daemon.stopHostedAgent(context.Background(), command.AgentId); err != nil {
		t.Fatalf("duplicate STOP did not retry only metadata cleanup: %v", err)
	}
	if _, err := daemon.startHostedAgent(context.Background(), command); err != nil {
		t.Fatalf("START after completed cleanup failed: %v", err)
	}
	second := <-started
	actualRemove := daemon.removeHostedCredential
	removeFailed := false
	daemon.removeHostedCredential = func(path string) error {
		if !removeFailed {
			removeFailed = true
			return errors.New("injected credential removal failure")
		}
		return actualRemove(path)
	}
	if _, err := daemon.stopHostedAgent(context.Background(), command.AgentId); err == nil {
		t.Fatal("credential removal failure was ignored")
	}
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := daemon.Stop(shutdownCtx); err != nil {
		t.Fatalf("daemon shutdown did not retry pending cleanup: %v", err)
	}
	select {
	case <-second.stopped:
	default:
		t.Fatal("second runtime was not stopped")
	}
	if files, _ := filepath.Glob(filepath.Join(root, "credentials", "*.json")); len(files) != 0 {
		t.Fatalf("credential leaked after shutdown retry: %v", files)
	}
}

func TestHostedStartRegistrationTimeoutRemovesSessionCredentialAndRetries(t *testing.T) {
	root := t.TempDir()
	_ = os.Chmod(root, 0o700)
	started := make(chan *compensationProcess, 2)
	hosted := HostedAdminConfig{StateDirectory: filepath.Join(root, "state"), PiSessionDirectory: filepath.Join(root, "sessions"), CredentialDirectory: filepath.Join(root, "credentials"), DefaultProjectDirectory: root, TrustProject: true, TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge", RuntimeFactory: func(hostedpi.Config) application.HostedPiRuntime { return compensationRuntime{started: started} }}
	daemon := delayedRegistryService(t, hosted)
	command := &subagentsv1.HostedAdminRequest{AgentId: "hosted-timeout", ProjectDirectory: root, TrustProject: true}
	if _, err := daemon.startHostedAgent(context.Background(), command); err == nil {
		t.Fatal("hosted START delay did not time out")
	}
	process := <-started
	select {
	case <-process.stopped:
	case <-time.After(time.Second):
		t.Fatal("hosted timeout did not stop runtime")
	}
	deadline := time.Now().Add(time.Second)
	var files []string
	for time.Now().Before(deadline) {
		files, _ = filepath.Glob(filepath.Join(root, "credentials", "*.json"))
		if len(files) == 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if len(files) != 0 {
		t.Fatalf("timed out START leaked credential: %v", files)
	}
	daemon.registrationTimeout = 500 * time.Millisecond
	binding, err := daemon.startHostedAgent(context.Background(), command)
	if err != nil {
		t.Fatalf("hosted START retry failed: %v", err)
	}
	if binding.TmuxSessionID == "" {
		t.Fatal("retry did not publish runtime")
	}
	if _, err := daemon.stopHostedAgent(context.Background(), command.AgentId); err != nil && !errors.Is(err, context.Canceled) {
		t.Fatalf("retry cleanup failed: %v", err)
	}
}
