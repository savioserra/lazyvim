package hostedpi

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/securepath"
	"golang.org/x/sys/unix"
)

var (
	ErrRuntimeAlreadyExists  = errors.New("hosted Pi runtime ownership record already exists")
	ErrUnexpectedRuntimeExit = errors.New("hosted Pi runtime disappeared unexpectedly")
	ErrRuntimeAbsent         = errors.New("hosted Pi runtime is proven absent")
)

type Config struct {
	TmuxBinary, PiBinary, BridgeExtension, DaemonSocket, CredentialFile string
	ServerName, TmuxConfig, ProjectDirectory, StateDirectory            string
	SessionID, GenerationID, CallerIdentity                             string
	TrustProject                                                        bool
}

type Runtime struct {
	Config           Config
	beforeAtomicKill func(string)
	writeRecord      func(string, any) error
	removeRecord     func(string) error
}

type ownershipRecord struct {
	SchemaVersion int                                `json:"schema_version"`
	Binding       application.HostedPiRuntimeBinding `json:"binding"`
	ServerName    string                             `json:"tmux_server_name,omitempty"`
}

type ownedProcess struct {
	config           Config
	record           ownershipRecord
	path             string
	done             chan error
	stopOnce         sync.Once
	completeOnce     sync.Once
	stopErr          error
	expectedStop     atomic.Bool
	beforeAtomicKill func(string)
}

func (r *Runtime) Start(ctx context.Context, spec application.HostedPiLaunchSpec) (application.HostedPiOwnedProcess, error) {
	if err := validate(r.Config, spec); err != nil {
		return nil, err
	}
	if err := privateDirectory(r.Config.StateDirectory); err != nil {
		return nil, err
	}
	if err := privateDirectory(spec.PiSessionDirectory); err != nil {
		return nil, err
	}
	recordName := runtimeRecordName(spec.RuntimeID)
	recordPath := filepath.Join(r.Config.StateDirectory, recordName+".json")
	if _, err := os.Lstat(recordPath); err == nil {
		return nil, ErrRuntimeAlreadyExists
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("inspect hosted binding record: %w", err)
	}
	lockPath := filepath.Join(r.Config.StateDirectory, "."+recordName+".lock")
	lock, err := os.OpenFile(lockPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		if errors.Is(err, os.ErrExist) {
			return nil, ErrRuntimeAlreadyExists
		}
		return nil, fmt.Errorf("create hosted runtime reservation: %w", err)
	}
	if err := lock.Close(); err != nil {
		return nil, err
	}
	releaseReservation := true
	defer func() {
		if releaseReservation {
			_ = os.Remove(lockPath)
		}
	}()
	// Recheck after exclusive reservation so concurrent starts cannot both launch.
	if _, err := os.Lstat(recordPath); err == nil {
		return nil, ErrRuntimeAlreadyExists
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}

	startupCtx, startupCancel := criticalStartupContext(ctx)
	defer startupCancel()
	args := hostedPiLaunchArgs(r.Config, spec)
	command := exec.CommandContext(startupCtx, r.Config.TmuxBinary, args...)
	output, err := command.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("create exactly owned tmux session: %w: %s", err, boundedText(output))
	}
	identity, err := parseCreatedIdentity(output)
	if err != nil {
		// new-session succeeded, so malformed output cannot prove which stable
		// tmux IDs were created. Retain both a degraded partial record and the
		// reservation: cleanup or retry by reusable name would be unsafe.
		partial := application.InactiveHostedPiRuntimeBinding()
		partial.State, partial.RuntimeID, partial.Incarnation, partial.TmuxSession, partial.TmuxWindow, partial.OwnershipIndeterminate = application.HostedPiRuntimeDegraded, spec.RuntimeID, spec.Incarnation, spec.TmuxSession, spec.TmuxWindow, true
		_ = atomicPrivateJSON(recordPath, ownershipRecord{SchemaVersion: 1, Binding: partial, ServerName: r.Config.ServerName})
		releaseReservation = false
		return nil, errors.Join(application.ErrHostedOwnershipIndeterminate, err)
	}

	binding, err := r.inspect(startupCtx, spec, identity)
	if err != nil {
		partial := application.InactiveHostedPiRuntimeBinding()
		partial.State, partial.RuntimeID, partial.Incarnation, partial.TmuxSession, partial.TmuxWindow, partial.TmuxPane, partial.TmuxSessionID, partial.TmuxWindowID, partial.TmuxServerPID, partial.OwnershipIndeterminate = application.HostedPiRuntimeDegraded, spec.RuntimeID, spec.Incarnation, spec.TmuxSession, spec.TmuxWindow, identity.paneID, identity.sessionID, identity.windowID, identity.serverPID, true
		if atomicPrivateJSON(recordPath, ownershipRecord{SchemaVersion: 1, Binding: partial, ServerName: r.Config.ServerName}) != nil {
			releaseReservation = false
		}
		return nil, errors.Join(application.ErrHostedOwnershipIndeterminate, fmt.Errorf("inspect new runtime before ownership mark (left fail-closed): %w", err))
	}
	if err := r.markOwnership(startupCtx, binding); err != nil {
		binding.State, binding.OwnershipIndeterminate = application.HostedPiRuntimeDegraded, true
		if atomicPrivateJSON(recordPath, ownershipRecord{SchemaVersion: 1, Binding: binding, ServerName: r.Config.ServerName}) != nil {
			releaseReservation = false
		}
		return nil, errors.Join(application.ErrHostedOwnershipIndeterminate, fmt.Errorf("mark exact tmux ownership (left fail-closed): %w", err))
	}
	record := ownershipRecord{SchemaVersion: 1, Binding: binding, ServerName: r.Config.ServerName}
	writeRecord := r.writeRecord
	if writeRecord == nil {
		writeRecord = atomicPrivateJSON
	}
	if err := writeRecord(recordPath, record); err != nil {
		// A failure after rename (notably directory fsync) may still have
		// published the exact record. Inspect it while the reservation is held,
		// roll back only the captured tmux identity, and remove+sync only an
		// exact published record. Any uncertainty remains fail-closed.
		exists, exact, inspectErr := inspectPublishedRecord(recordPath, record)
		rollbackCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		cleanupErr := r.killCaptured(rollbackCtx, binding, "startup-rollback")
		if inspectErr != nil || cleanupErr != nil || (exists && !exact) {
			releaseReservation = false
			return nil, errors.Join(application.ErrHostedOwnershipIndeterminate, err, inspectErr, cleanupErr)
		}
		if exact {
			removeRecord := r.removeRecord
			if removeRecord == nil {
				removeRecord = removePrivateRecord
			}
			if removeErr := removeRecord(recordPath); removeErr != nil {
				releaseReservation = false
				return nil, errors.Join(application.ErrHostedOwnershipIndeterminate, err, removeErr)
			}
		}
		return nil, err
	}
	process := &ownedProcess{config: r.Config, record: record, path: recordPath, done: make(chan error, 1), beforeAtomicKill: r.beforeAtomicKill}
	go process.observe()
	return process, nil
}

func hostedPiLaunchArgs(config Config, spec application.HostedPiLaunchSpec) []string {
	args := tmuxPrefix(config)
	args = append(args, "new-session", "-d", "-P", "-F", "#{session_id}\t#{window_id}\t#{pane_id}\t#{pid}", "-s", spec.TmuxSession, "-n", spec.TmuxWindow,
		"-e", "WS_SUBAGENTS_SOCKET="+config.DaemonSocket,
		"-e", "WS_SUBAGENTS_CREDENTIAL_FILE="+config.CredentialFile,
		"-e", "WS_SUBAGENTS_SESSION_ID="+config.SessionID,
		"-e", "WS_SUBAGENTS_GENERATION_ID="+config.GenerationID,
		"-e", "WS_SUBAGENTS_CALLER="+config.CallerIdentity,
		"-e", "WS_SUBAGENTS_AGENT_ID="+spec.AgentID,
		"-e", "WS_SUBAGENTS_RUNTIME_ID="+spec.RuntimeID,
		"-e", fmt.Sprintf("WS_SUBAGENTS_INCARNATION=%d", spec.Incarnation),
		"-c", config.ProjectDirectory,
		config.PiBinary, "--tui-mode", "fullscreen", "--session-dir", spec.PiSessionDirectory, "--name", spec.PiSessionName, "-e", config.BridgeExtension)
	if config.TrustProject {
		args = append(args, "--approve")
	} else {
		args = append(args, "--no-approve")
	}
	return args
}

func criticalStartupContext(parent context.Context) (context.Context, context.CancelFunc) {
	// Once tmux new-session can create an externally visible session, caller
	// cancellation must not kill the tmux client before stdout is captured and
	// the exact ownership tuple is marked. Very short deadlines still bound
	// obviously-wrong binaries that never reach tmux.
	if deadline, ok := parent.Deadline(); ok && time.Until(deadline) < time.Second {
		return context.WithDeadline(context.WithoutCancel(parent), deadline)
	}
	return context.WithTimeout(context.WithoutCancel(parent), 30*time.Second)
}

func (r *Runtime) Adopt(ctx context.Context, spec application.HostedPiLaunchSpec, binding application.HostedPiRuntimeBinding) (application.HostedPiOwnedProcess, error) {
	if err := validate(r.Config, spec); err != nil {
		return nil, err
	}
	if binding.RuntimeID != spec.RuntimeID || binding.Incarnation != spec.Incarnation {
		return nil, application.ErrHostedOwnershipIndeterminate
	}
	present, err := sessionExists(ctx, r.Config, binding)
	if err != nil {
		return nil, errors.Join(application.ErrHostedOwnershipIndeterminate, err)
	}
	if !present {
		return nil, ErrRuntimeAbsent
	}
	serverToken, err := processStartToken(ctx, binding.TmuxServerPID)
	if err != nil || serverToken != binding.TmuxServerStartToken {
		return nil, errors.Join(application.ErrHostedOwnershipIndeterminate, fmt.Errorf("tmux server process token changed: %v", err))
	}
	paneToken, err := processStartToken(ctx, binding.PanePID)
	if err != nil || paneToken != binding.ProcessStartToken {
		return nil, errors.Join(application.ErrHostedOwnershipIndeterminate, fmt.Errorf("pane process token changed: %v", err))
	}
	path := filepath.Join(r.Config.StateDirectory, runtimeRecordName(spec.RuntimeID)+".json")
	recorded, err := LoadOwnershipBinding(r.Config.StateDirectory, spec.RuntimeID)
	if err != nil || !sameOwnedIdentity(recorded, binding) {
		return nil, errors.Join(application.ErrHostedOwnershipIndeterminate, err, errors.New("ownership publication identity mismatch"))
	}
	record := ownershipRecord{SchemaVersion: 1, Binding: recorded, ServerName: r.Config.ServerName}
	process := &ownedProcess{config: r.Config, record: record, path: path, done: make(chan error, 1), beforeAtomicKill: r.beforeAtomicKill}
	go process.observe()
	return process, nil
}

type tmuxIdentity struct {
	sessionID, windowID, paneID string
	serverPID                   int64
}

func parseCreatedIdentity(output []byte) (tmuxIdentity, error) {
	fields := strings.Split(strings.TrimSpace(string(output)), "\t")
	if len(fields) != 4 || !strings.HasPrefix(fields[0], "$") || !strings.HasPrefix(fields[1], "@") || !strings.HasPrefix(fields[2], "%") {
		return tmuxIdentity{}, errors.New("tmux returned incomplete stable creation identity")
	}
	serverPID, err := strconv.ParseInt(fields[3], 10, 64)
	if err != nil || serverPID < 1 {
		return tmuxIdentity{}, errors.New("tmux returned invalid server PID")
	}
	return tmuxIdentity{sessionID: fields[0], windowID: fields[1], paneID: fields[2], serverPID: serverPID}, nil
}

func (r *Runtime) inspect(ctx context.Context, spec application.HostedPiLaunchSpec, expected tmuxIdentity) (application.HostedPiRuntimeBinding, error) {
	args := append(tmuxPrefix(r.Config), "display-message", "-p", "-t", expected.paneID, "#{session_id}\t#{window_id}\t#{pane_id}\t#{session_name}\t#{window_name}\t#{pane_pid}\t#{pane_tty}\t#{pid}")
	var output []byte
	var err error
	deadline := time.Now().Add(3 * time.Second)
	for {
		output, err = exec.CommandContext(ctx, r.Config.TmuxBinary, args...).Output()
		if err == nil {
			break
		}
		if time.Now().After(deadline) {
			return application.HostedPiRuntimeBinding{}, fmt.Errorf("inspect owned tmux pane: %w", err)
		}
		time.Sleep(20 * time.Millisecond)
	}
	fields := strings.Split(strings.TrimSpace(string(output)), "\t")
	if len(fields) != 8 || fields[0] != expected.sessionID || fields[1] != expected.windowID || fields[2] != expected.paneID || fields[3] != spec.TmuxSession || fields[4] != spec.TmuxWindow || fields[6] == "" || fields[7] != strconv.FormatInt(expected.serverPID, 10) {
		return application.HostedPiRuntimeBinding{}, errors.New("tmux returned incomplete or mismatched ownership identity")
	}
	pid, err := strconv.ParseInt(fields[5], 10, 64)
	if err != nil || pid < 1 {
		return application.HostedPiRuntimeBinding{}, errors.New("tmux returned invalid pane PID")
	}
	token, err := processStartToken(ctx, pid)
	if err != nil {
		return application.HostedPiRuntimeBinding{}, fmt.Errorf("read pane process start proof: %w", err)
	}
	serverToken, err := processStartToken(ctx, expected.serverPID)
	if err != nil {
		return application.HostedPiRuntimeBinding{}, fmt.Errorf("read tmux server start proof: %w", err)
	}
	return application.HostedPiRuntimeBinding{
		State: application.HostedPiRuntimeStarting, Lifetime: application.HostedPiLifetimeGlobalAgent,
		TmuxOwnership: application.HostedPiTmuxOwnershipExactSession, ControlBoundary: application.HostedPiControlDocumentedBridgeOnly,
		VisualizationBoundary: application.HostedPiVisualizationTmuxAttach, RuntimeID: spec.RuntimeID, Incarnation: spec.Incarnation,
		TmuxSession: fields[3], TmuxWindow: fields[4], TmuxPane: fields[2], TmuxSessionID: fields[0], TmuxWindowID: fields[1], TmuxServerPID: expected.serverPID, TmuxServerStartToken: serverToken, PanePID: pid, ProcessStartToken: token,
		TTY: fields[6], PiSessionDirectory: spec.PiSessionDirectory, PiSessionName: spec.PiSessionName,
	}, nil
}

func (p *ownedProcess) Binding() application.HostedPiRuntimeBinding { return p.record.Binding }
func (p *ownedProcess) Wait() error                                 { return <-p.done }
func (p *ownedProcess) complete(err error)                          { p.completeOnce.Do(func() { p.done <- err }) }
func (p *ownedProcess) observe() {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	failures := 0
	for range ticker.C {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		present, err := sessionExists(ctx, p.config, p.record.Binding)
		cancel()
		if err != nil {
			failures++
			if failures >= 3 {
				p.complete(fmt.Errorf("indeterminate tmux observation failure: %w", err))
				return
			}
			continue
		}
		failures = 0
		if !present {
			if p.expectedStop.Load() {
				return
			}
			if err := removePrivateRecord(p.path); err != nil {
				p.complete(fmt.Errorf("unexpected runtime loss record cleanup: %w", err))
				return
			}
			p.complete(ErrUnexpectedRuntimeExit)
			return
		}
	}
}
func (p *ownedProcess) Stop(ctx context.Context) error {
	p.stopOnce.Do(func() {
		p.expectedStop.Store(true)
		runtime := Runtime{Config: p.config, beforeAtomicKill: p.beforeAtomicKill}
		owned := p.record.Binding
		serverToken, err := processStartToken(ctx, owned.TmuxServerPID)
		if err != nil || serverToken != owned.TmuxServerStartToken {
			p.stopErr = errors.New("refusing cleanup because tmux server ownership changed")
			p.complete(p.stopErr)
			return
		}
		paneToken, err := processStartToken(ctx, owned.PanePID)
		if err != nil || paneToken != owned.ProcessStartToken {
			p.stopErr = errors.New("refusing cleanup because pane process ownership changed")
			p.complete(p.stopErr)
			return
		}
		p.stopErr = runtime.killCaptured(ctx, owned, "stop")
		if p.stopErr == nil {
			p.stopErr = removePrivateRecord(p.path)
		}
		p.complete(p.stopErr)
	})
	return p.stopErr
}

func sessionExists(ctx context.Context, config Config, binding application.HostedPiRuntimeBinding) (bool, error) {
	args := append(tmuxPrefix(config), "display-message", "-p", "-t", binding.TmuxPane, "#{pid}\t#{session_id}\t#{window_id}\t#{pane_id}\t#{pane_pid}\t#{pane_tty}\t#{@ws_hosted_server_start}\t#{@ws_hosted_process_start}")
	output, err := exec.CommandContext(ctx, config.TmuxBinary, args...).CombinedOutput()
	if err != nil {
		if strings.Contains(string(output), "no server running") || strings.Contains(string(output), "failed to connect") || strings.Contains(string(output), "can't find") {
			return false, nil
		}
		return false, fmt.Errorf("inspect tmux runtime lease: %w: %s", err, boundedText(output))
	}
	fields := strings.Split(strings.TrimSpace(string(output)), "\t")
	if len(fields) != 8 || fields[0] != strconv.FormatInt(binding.TmuxServerPID, 10) || fields[1] != binding.TmuxSessionID || fields[2] != binding.TmuxWindowID || fields[3] != binding.TmuxPane || fields[4] != strconv.FormatInt(binding.PanePID, 10) || fields[5] != binding.TTY || fields[6] != ownershipDigest(binding.TmuxServerStartToken) || fields[7] != ownershipDigest(binding.ProcessStartToken) {
		return false, errors.New("tmux runtime identity was replaced")
	}
	return true, nil
}

func (r *Runtime) markOwnership(ctx context.Context, binding application.HostedPiRuntimeBinding) error {
	serverMarker, processMarker := ownershipDigest(binding.TmuxServerStartToken), ownershipDigest(binding.ProcessStartToken)
	args := append(tmuxPrefix(r.Config), "set-option", "-p", "-t", binding.TmuxPane, "@ws_hosted_server_start", serverMarker, ";", "set-option", "-p", "-t", binding.TmuxPane, "@ws_hosted_process_start", processMarker)
	if output, err := exec.CommandContext(ctx, r.Config.TmuxBinary, args...).CombinedOutput(); err != nil {
		return fmt.Errorf("mark tmux ownership tuple: %w: %s", err, boundedText(output))
	}
	return nil
}

func (r *Runtime) killCaptured(ctx context.Context, binding application.HostedPiRuntimeBinding, reason string) error {
	comparisons := []string{
		fmt.Sprintf("#{==:#{pid},%d}", binding.TmuxServerPID),
		fmt.Sprintf("#{==:#{session_id},%s}", binding.TmuxSessionID), fmt.Sprintf("#{==:#{window_id},%s}", binding.TmuxWindowID), fmt.Sprintf("#{==:#{pane_id},%s}", binding.TmuxPane),
		fmt.Sprintf("#{==:#{pane_pid},%d}", binding.PanePID), fmt.Sprintf("#{==:#{pane_tty},%s}", binding.TTY),
		fmt.Sprintf("#{==:#{@ws_hosted_server_start},%s}", ownershipDigest(binding.TmuxServerStartToken)), fmt.Sprintf("#{==:#{@ws_hosted_process_start},%s}", ownershipDigest(binding.ProcessStartToken)),
	}
	predicate := comparisons[0]
	for _, comparison := range comparisons[1:] {
		predicate = "#{&&:" + predicate + "," + comparison + "}"
	}
	if r.beforeAtomicKill != nil {
		r.beforeAtomicKill(reason)
	}
	args := append(tmuxPrefix(r.Config), "if-shell", "-F", "-t", binding.TmuxPane, predicate, "kill-session -t "+binding.TmuxSessionID, "display-message -p -t "+binding.TmuxPane+" ownership-mismatch")
	output, err := exec.CommandContext(ctx, r.Config.TmuxBinary, args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("atomic exact tmux cleanup: %w: %s", err, boundedText(output))
	}
	if strings.Contains(string(output), "ownership-mismatch") {
		return errors.New("refusing cleanup because atomic tmux ownership predicate failed")
	}
	return nil
}

func sameOwnedIdentity(left, right application.HostedPiRuntimeBinding) bool {
	return left.RuntimeID == right.RuntimeID && left.Incarnation == right.Incarnation && left.TmuxSession == right.TmuxSession && left.TmuxWindow == right.TmuxWindow && left.TmuxPane == right.TmuxPane && left.TmuxSessionID == right.TmuxSessionID && left.TmuxWindowID == right.TmuxWindowID && left.TmuxServerPID == right.TmuxServerPID && left.TmuxServerStartToken == right.TmuxServerStartToken && left.PanePID == right.PanePID && left.ProcessStartToken == right.ProcessStartToken && left.TTY == right.TTY && left.PiSessionDirectory == right.PiSessionDirectory && left.PiSessionName == right.PiSessionName
}
func ownershipDigest(value string) string {
	digest := sha256.Sum256([]byte(value))
	return hex.EncodeToString(digest[:])
}

func tmuxPrefix(config Config) []string {
	var args []string
	if config.ServerName != "" {
		args = append(args, "-L", config.ServerName)
	}
	if config.TmuxConfig != "" {
		args = append(args, "-f", config.TmuxConfig)
	}
	return args
}

func validate(config Config, spec application.HostedPiLaunchSpec) error {
	for name, value := range map[string]string{"tmux binary": config.TmuxBinary, "Pi binary": config.PiBinary, "bridge extension": config.BridgeExtension, "daemon socket": config.DaemonSocket, "credential file": config.CredentialFile, "project directory": config.ProjectDirectory, "state directory": config.StateDirectory, "agent id": spec.AgentID, "runtime id": spec.RuntimeID, "tmux session": spec.TmuxSession, "tmux window": spec.TmuxWindow, "Pi session directory": spec.PiSessionDirectory, "Pi session name": spec.PiSessionName} {
		if value == "" || value != strings.TrimSpace(value) || strings.ContainsAny(value, "\x00\r\n") {
			return fmt.Errorf("%s is required and must be trim-equal", name)
		}
	}
	if spec.Incarnation == 0 || strings.HasPrefix(spec.TmuxSession, "-") || strings.ContainsAny(spec.TmuxSession, ":. ") {
		return errors.New("invalid hosted runtime incarnation or tmux session name")
	}
	return nil
}

func privateDirectory(path string) error {
	directory, err := securepath.EnsureDir(path, 0o700, func(current string, info os.FileInfo, final bool) error {
		uid, mode := info.Sys().(*syscall.Stat_t).Uid, info.Mode().Perm()
		if final {
			if uid != uint32(os.Getuid()) || mode != 0o700 {
				return errors.New("hosted Pi directory is not exactly owner-private")
			}
			return nil
		}
		if uid != 0 && uid != uint32(os.Getuid()) {
			return fmt.Errorf("hosted Pi ancestor %s has foreign ownership", current)
		}
		if mode&0o022 != 0 && info.Mode()&os.ModeSticky == 0 {
			return fmt.Errorf("hosted Pi ancestor %s is writable without sticky bit", current)
		}
		return nil
	})
	if err != nil {
		return err
	}
	return directory.Close()
}

// WriteCredentialFile creates or atomically replaces an exactly owner-private
// credential JSON file after descriptor-relative directory creation.
func WriteCredentialFile(path string, credential []byte, exclusive bool) error {
	if len(credential) != 32 || !filepath.IsAbs(path) {
		return errors.New("credential path must be absolute and credential must be 32 bytes")
	}
	if err := privateDirectory(filepath.Dir(path)); err != nil {
		return err
	}
	value := map[string]string{"credential_b64": base64.StdEncoding.EncodeToString(credential)}
	if !exclusive {
		return atomicPrivateJSON(path, value)
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return err
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	failed := true
	defer func() {
		if failed {
			_ = os.Remove(path)
		}
	}()
	if _, err := file.Write(append(encoded, '\n')); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := syncDirectory(filepath.Dir(path)); err != nil {
		return err
	}
	failed = false
	return nil
}
func ReadCredentialFile(path string) ([]byte, error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("credential path must be absolute")
	}
	dir, err := securepath.OpenDir(filepath.Dir(path), func(current string, info os.FileInfo, final bool) error {
		if final {
			stat := info.Sys().(*syscall.Stat_t)
			if stat.Uid != uint32(os.Getuid()) || info.Mode().Perm() != 0o700 {
				return errors.New("credential directory is not owner-private")
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	defer dir.Close()
	fd, err := unix.Openat(int(dir.Fd()), filepath.Base(path), unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) || info.Size() > 256 {
		return nil, errors.New("credential file is unsafe")
	}
	var value map[string]string
	if err = json.NewDecoder(io.LimitReader(file, 257)).Decode(&value); err != nil {
		return nil, err
	}
	if len(value) != 1 {
		return nil, errors.New("credential file schema mismatch")
	}
	credential, err := base64.StdEncoding.DecodeString(value["credential_b64"])
	if err != nil || len(credential) != 32 {
		return nil, errors.New("credential file value is invalid")
	}
	return credential, nil
}
func RemoveCredentialFile(path string) error { return removePrivateRecord(path) }
func RemoveOwnershipRecord(stateDirectory, runtimeID string) error {
	return removePrivateRecord(filepath.Join(stateDirectory, runtimeRecordName(runtimeID)+".json"))
}

func atomicPrivateJSON(path string, value any) error {
	encoded, err := json.Marshal(value)
	if err != nil {
		return err
	}
	directory := filepath.Dir(path)
	temporary, err := os.CreateTemp(directory, ".binding-*")
	if err != nil {
		return err
	}
	name := temporary.Name()
	defer os.Remove(name)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	writer := bufio.NewWriter(temporary)
	if _, err := writer.Write(append(encoded, '\n')); err != nil {
		temporary.Close()
		return err
	}
	if err := writer.Flush(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(name, path); err != nil {
		return err
	}
	return syncDirectory(directory)
}

func LoadOwnershipBinding(stateDirectory, runtimeID string) (application.HostedPiRuntimeBinding, error) {
	dir, err := securepath.OpenDir(stateDirectory, func(current string, info os.FileInfo, final bool) error {
		if final && (info.Mode().Perm() != 0o700 || info.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid())) {
			return errors.New("hosted ownership directory is unsafe")
		}
		return nil
	})
	if err != nil {
		return application.HostedPiRuntimeBinding{}, err
	}
	defer dir.Close()
	fd, err := unix.Openat(int(dir.Fd()), runtimeRecordName(runtimeID)+".json", unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return application.HostedPiRuntimeBinding{}, err
	}
	file := os.NewFile(uintptr(fd), runtimeID)
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return application.HostedPiRuntimeBinding{}, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Sys().(*syscall.Stat_t).Uid != uint32(os.Getuid()) || info.Size() > 64*1024 {
		return application.HostedPiRuntimeBinding{}, errors.New("hosted ownership record is unsafe")
	}
	contents, err := io.ReadAll(io.LimitReader(file, 64*1024+1))
	if err != nil {
		return application.HostedPiRuntimeBinding{}, err
	}
	var record ownershipRecord
	if err = json.Unmarshal(contents, &record); err != nil {
		return application.HostedPiRuntimeBinding{}, err
	}
	if record.SchemaVersion != 1 || record.Binding.RuntimeID != runtimeID {
		return application.HostedPiRuntimeBinding{}, errors.New("hosted ownership record identity mismatch")
	}
	return record.Binding, nil
}

func inspectPublishedRecord(path string, expected ownershipRecord) (exists, exact bool, err error) {
	contents, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, false, nil
	}
	if err != nil {
		return false, false, fmt.Errorf("inspect potentially published hosted binding: %w", err)
	}
	var actual ownershipRecord
	if err := json.Unmarshal(contents, &actual); err != nil {
		return true, false, fmt.Errorf("decode potentially published hosted binding: %w", err)
	}
	return true, actual == expected, nil
}

func removePrivateRecord(path string) error {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return syncDirectory(filepath.Dir(path))
}
func syncDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}
func runtimeRecordName(runtimeID string) string {
	digest := sha256.Sum256([]byte(runtimeID))
	return hex.EncodeToString(digest[:16])
}

func boundedText(value []byte) string {
	if len(value) > 1024 {
		value = value[:1024]
	}
	return strings.TrimSpace(string(value))
}
