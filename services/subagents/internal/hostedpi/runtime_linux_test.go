//go:build linux

package hostedpi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

func buildSleepingPi(t *testing.T, directory string) string {
	t.Helper()
	source := filepath.Join(directory, "pi.go")
	binary := filepath.Join(directory, "pi-helper")
	if err := os.WriteFile(source, []byte("package main\nimport \"time\"\nfunc main(){time.Sleep(time.Minute)}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	command := exec.Command("go", "build", "-o", binary, source)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("build Pi helper: %v: %s", err, output)
	}
	return binary
}

func TestHostedPiLaunchArgsUseFullscreenTUIBeforeSessionOptions(t *testing.T) {
	config := Config{TmuxBinary: "/tmux", PiBinary: "/pi", BridgeExtension: "/bridge.ts", DaemonEndpoint: "ws://127.0.0.1:17213/actors", CredentialFile: "/credential.json", ServerName: "server", TmuxConfig: "/tmux.conf", ProjectDirectory: "/project", SessionID: "session", GenerationID: "generation", CallerIdentity: "hosted:agent", TrustProject: true}
	spec := application.HostedPiLaunchSpec{AgentID: "agent", RuntimeID: "runtime", Incarnation: 1, TmuxSession: "tmux-session", TmuxWindow: "pi", PiSessionDirectory: "/pi-sessions", PiSessionName: "pi-session"}
	args := hostedPiLaunchArgs(config, spec)

	piIndex := indexOf(args, "/pi")
	if piIndex < 0 {
		t.Fatalf("Pi binary missing from launch args: %#v", args)
	}
	want := []string{"/pi", "--no-extensions", "--tui-mode", "fullscreen", "--session-dir", "/pi-sessions", "--name", "pi-session", "-e", "/bridge.ts", "--approve"}
	if got := args[piIndex:]; !equalStrings(got, want) {
		t.Fatalf("Pi launch suffix mismatch\n got: %#v\nwant: %#v", got, want)
	}
	pathIndex := indexOf(args, "PATH=/"+string(os.PathListSeparator)+os.Getenv("PATH"))
	if pathIndex < 1 || args[pathIndex-1] != "-e" {
		t.Fatalf("hosted tmux PATH must include the Pi binary directory: %#v", args)
	}
	if indexOf(args, "send-keys") >= 0 || indexOf(args, "respawn-pane") >= 0 {
		t.Fatalf("launch args must keep tmux visualization-only and exact-owned: %#v", args)
	}
}

func TestRuntimeUsesStableTmuxIDsAndRefusesForeignNameReplacement(t *testing.T) {
	tmux, err := exec.LookPath("tmux")
	if err != nil {
		t.Skip("tmux unavailable")
	}
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	tmuxTmp, err := os.MkdirTemp("/tmp", "ws-hp-unit-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(tmuxTmp) })
	t.Setenv("TMUX_TMPDIR", tmuxTmp)
	server := "ws-hosted-unit"
	configPath := filepath.Join(root, "tmux.conf")
	if err := os.WriteFile(configPath, []byte("set -g pane-base-index 1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	pi := buildSleepingPi(t, root)
	runtime := &Runtime{Config: Config{TmuxBinary: tmux, PiBinary: pi, BridgeExtension: filepath.Join(root, "bridge.ts"), DaemonEndpoint: filepath.Join(root, "daemon.sock"), CredentialFile: filepath.Join(root, "credential.json"), ServerName: server, TmuxConfig: configPath, ProjectDirectory: root, StateDirectory: filepath.Join(root, "state"), SessionID: "session", GenerationID: "generation", CallerIdentity: "hosted:agent", TrustProject: true}}
	runtime.beforeAtomicKill = func(reason string) {
		if reason != "stop" {
			return
		}
		_ = exec.Command(tmux, "-L", server, "kill-server").Run()
		if output, err := exec.Command(tmux, "-L", server, "-f", configPath, "new-session", "-d", "-s", "stable-name", pi).CombinedOutput(); err != nil {
			t.Fatalf("create race-window replacement: %v: %s", err, output)
		}
	}
	spec := application.HostedPiLaunchSpec{AgentID: "agent", RuntimeID: "runtime", Incarnation: 1, TmuxSession: "stable-name", TmuxWindow: "pi", PiSessionDirectory: filepath.Join(root, "sessions"), PiSessionName: "pi-session"}
	process, err := runtime.Start(context.Background(), spec)
	if err != nil {
		t.Fatal(err)
	}
	binding := process.Binding()
	if !strings.HasPrefix(binding.TmuxSessionID, "$") || !strings.HasPrefix(binding.TmuxWindowID, "@") || !strings.HasPrefix(binding.TmuxPane, "%") || binding.TmuxServerPID < 1 || binding.TmuxServerStartToken == "" {
		t.Fatalf("stable tmux IDs not captured: %#v", binding)
	}
	stopCtx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := process.Stop(stopCtx); err == nil {
		t.Fatal("cleanup accepted a foreign replacement")
	}
	if err := exec.Command(tmux, "-L", server, "has-session", "-t", spec.TmuxSession).Run(); err != nil {
		t.Fatal("exact cleanup killed the foreign replacement")
	}
	_ = exec.Command(tmux, "-L", server, "kill-server").Run()
}

func buildDelayedTmuxProxy(t *testing.T, directory, tmux string, delay time.Duration) string {
	t.Helper()
	source, binary := filepath.Join(directory, "tmux-delay.go"), filepath.Join(directory, "tmux-delay")
	program := "package main\nimport (\"os\";\"os/exec\";\"time\")\nfunc main(){time.Sleep(" + fmt.Sprintf("%d", delay.Nanoseconds()) + "*time.Nanosecond); c:=exec.Command(" + fmt.Sprintf("%q", tmux) + ",os.Args[1:]...); c.Stdout=os.Stdout; c.Stderr=os.Stderr; if err:=c.Run(); err!=nil { if x,ok:=err.(*exec.ExitError); ok { os.Exit(x.ExitCode()) }; panic(err) }}\n"
	if err := os.WriteFile(source, []byte(program), 0o600); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command("go", "build", "-o", binary, source).CombinedOutput(); err != nil {
		t.Fatalf("build delayed tmux proxy: %v: %s", err, output)
	}
	return binary
}

func TestRuntimeStartupCriticalSectionOutlivesCallerCancellation(t *testing.T) {
	tmux, err := exec.LookPath("tmux")
	if err != nil {
		t.Skip("tmux unavailable")
	}
	root := t.TempDir()
	_ = os.Chmod(root, 0o700)
	tmuxTmp, _ := os.MkdirTemp("/tmp", "ws-hp-cancel-")
	t.Cleanup(func() { _ = os.RemoveAll(tmuxTmp) })
	t.Setenv("TMUX_TMPDIR", tmuxTmp)
	server, configPath := "ws-hosted-cancel", filepath.Join(root, "tmux.conf")
	_ = os.WriteFile(configPath, []byte("set -g status off\n"), 0o600)
	pi := buildSleepingPi(t, root)
	proxy := buildDelayedTmuxProxy(t, root, tmux, 150*time.Millisecond)
	runtime := &Runtime{Config: Config{TmuxBinary: proxy, PiBinary: pi, BridgeExtension: filepath.Join(root, "bridge.ts"), DaemonEndpoint: filepath.Join(root, "daemon.sock"), CredentialFile: filepath.Join(root, "credential.json"), ServerName: server, TmuxConfig: configPath, ProjectDirectory: root, StateDirectory: filepath.Join(root, "state"), SessionID: "session", GenerationID: "generation", CallerIdentity: "hosted:agent", TrustProject: true}}
	spec := application.HostedPiLaunchSpec{AgentID: "agent", RuntimeID: "cancel-runtime", Incarnation: 1, TmuxSession: "cancel-name", TmuxWindow: "pi", PiSessionDirectory: filepath.Join(root, "sessions"), PiSessionName: "pi-session"}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		time.Sleep(20 * time.Millisecond)
		cancel()
		close(done)
	}()
	process, err := runtime.Start(ctx, spec)
	<-done
	if err != nil {
		t.Fatalf("caller cancellation escaped the exact startup section: %v", err)
	}
	stopCtx, stopCancel := context.WithTimeout(context.Background(), time.Second)
	defer stopCancel()
	if err := process.Stop(stopCtx); err != nil {
		t.Fatalf("exact cleanup after canceled caller failed: %v", err)
	}
	if err := exec.Command(tmux, "-L", server, "has-session", "-t", spec.TmuxSession).Run(); err == nil {
		t.Fatal("exact tmux session survived cleanup")
	}
}

func TestAdoptRequiresExactMarkersAndLeavesForeignIdentityUntouched(t *testing.T) {
	tmux, err := exec.LookPath("tmux")
	if err != nil {
		t.Skip("tmux unavailable")
	}
	root := t.TempDir()
	_ = os.Chmod(root, 0o700)
	tmuxTmp, err := os.MkdirTemp("/tmp", "ws-adopt-unit-")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("TMUX_TMPDIR", tmuxTmp)
	t.Cleanup(func() { _ = os.RemoveAll(tmuxTmp) })
	server := "ws-adopt-unit"
	configPath := filepath.Join(root, "tmux.conf")
	_ = os.WriteFile(configPath, []byte("set -g status off\n"), 0o600)
	pi := buildSleepingPi(t, root)
	runtime := &Runtime{Config: Config{TmuxBinary: tmux, PiBinary: pi, BridgeExtension: filepath.Join(root, "bridge.ts"), DaemonEndpoint: filepath.Join(root, "daemon.sock"), CredentialFile: filepath.Join(root, "credential.json"), ServerName: server, TmuxConfig: configPath, ProjectDirectory: root, StateDirectory: filepath.Join(root, "state"), SessionID: "session", GenerationID: "generation", CallerIdentity: "hosted:agent", TrustProject: true}}
	spec := application.HostedPiLaunchSpec{AgentID: "agent", RuntimeID: "runtime", Incarnation: 1, TmuxSession: "stable-adopt", TmuxWindow: "pi", PiSessionDirectory: filepath.Join(root, "sessions"), PiSessionName: "pi-session"}
	process, err := runtime.Start(context.Background(), spec)
	if err != nil {
		t.Fatal(err)
	}
	binding := process.Binding()
	adopted, err := runtime.Adopt(context.Background(), spec, binding)
	if err != nil {
		t.Fatalf("exact adoption failed: %v", err)
	}
	_ = adopted
	if output, err := exec.Command(tmux, "-L", server, "set-option", "-p", "-t", binding.TmuxPane, "@ws_hosted_process_start", "foreign").CombinedOutput(); err != nil {
		t.Fatalf("replace marker: %v %s", err, output)
	}
	if _, err := runtime.Adopt(context.Background(), spec, binding); !errors.Is(err, application.ErrHostedOwnershipIndeterminate) {
		t.Fatalf("foreign marker adoption did not fail closed: %v", err)
	}
	if err := exec.Command(tmux, "-L", server, "has-session", "-t", binding.TmuxSessionID).Run(); err != nil {
		t.Fatal("failed adoption changed foreign/replaced session")
	}
	_ = exec.Command(tmux, "-L", server, "kill-server").Run()
}

func TestStartupRollbackAtomicPredicatePreservesRaceWindowReplacement(t *testing.T) {
	tmux, err := exec.LookPath("tmux")
	if err != nil {
		t.Skip("tmux unavailable")
	}
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	tmuxTmp, err := os.MkdirTemp("/tmp", "ws-hp-rollback-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(tmuxTmp) })
	t.Setenv("TMUX_TMPDIR", tmuxTmp)
	server, configPath := "ws-hosted-rollback", filepath.Join(root, "tmux.conf")
	if err := os.WriteFile(configPath, []byte("set -g pane-base-index 1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	pi := buildSleepingPi(t, root)
	runtime := &Runtime{Config: Config{TmuxBinary: tmux, PiBinary: pi, BridgeExtension: filepath.Join(root, "bridge.ts"), DaemonEndpoint: filepath.Join(root, "daemon.sock"), CredentialFile: filepath.Join(root, "credential.json"), ServerName: server, TmuxConfig: configPath, ProjectDirectory: root, StateDirectory: filepath.Join(root, "state"), SessionID: "session", GenerationID: "generation", CallerIdentity: "hosted:agent", TrustProject: true}}
	runtime.writeRecord = func(string, any) error { return errors.New("forced record failure") }
	runtime.beforeAtomicKill = func(reason string) {
		if reason != "startup-rollback" {
			return
		}
		_ = exec.Command(tmux, "-L", server, "kill-server").Run()
		if output, err := exec.Command(tmux, "-L", server, "-f", configPath, "new-session", "-d", "-s", "rollback-name", pi).CombinedOutput(); err != nil {
			t.Fatalf("create rollback race replacement: %v: %s", err, output)
		}
	}
	spec := application.HostedPiLaunchSpec{AgentID: "agent", RuntimeID: "runtime", Incarnation: 1, TmuxSession: "rollback-name", TmuxWindow: "pi", PiSessionDirectory: filepath.Join(root, "sessions"), PiSessionName: "pi-session"}
	if _, err := runtime.Start(context.Background(), spec); err == nil {
		t.Fatal("forced record failure unexpectedly started")
	}
	if err := exec.Command(tmux, "-L", server, "has-session", "-t", spec.TmuxSession).Run(); err != nil {
		t.Fatal("startup rollback killed the foreign replacement")
	}
	_ = exec.Command(tmux, "-L", server, "kill-server").Run()
}

func buildMalformedTmuxProxy(t *testing.T, directory, tmux string) string {
	t.Helper()
	source, binary := filepath.Join(directory, "tmux-proxy.go"), filepath.Join(directory, "tmux-proxy")
	program := "package main\nimport (\"fmt\";\"os\";\"os/exec\")\nfunc main(){ c:=exec.Command(" + fmt.Sprintf("%q", tmux) + ",os.Args[1:]...); c.Stderr=os.Stderr; if err:=c.Run(); err!=nil { if x,ok:=err.(*exec.ExitError); ok { os.Exit(x.ExitCode()) }; panic(err) }; fmt.Println(\"malformed-success\") }\n"
	if err := os.WriteFile(source, []byte(program), 0o600); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.Command("go", "build", "-o", binary, source).CombinedOutput(); err != nil {
		t.Fatalf("build malformed tmux proxy: %v: %s", err, output)
	}
	return binary
}

func TestSuccessfulTmuxWithMalformedIdentityRemainsReservedAndIndeterminate(t *testing.T) {
	tmux, err := exec.LookPath("tmux")
	if err != nil {
		t.Skip("tmux unavailable")
	}
	root := t.TempDir()
	_ = os.Chmod(root, 0o700)
	tmuxTmp, _ := os.MkdirTemp("/tmp", "ws-hp-malformed-")
	t.Cleanup(func() { _ = os.RemoveAll(tmuxTmp) })
	t.Setenv("TMUX_TMPDIR", tmuxTmp)
	server, configPath := "ws-hosted-malformed", filepath.Join(root, "tmux.conf")
	_ = os.WriteFile(configPath, []byte("set -g pane-base-index 1\n"), 0o600)
	pi := buildSleepingPi(t, root)
	proxy := buildMalformedTmuxProxy(t, root, tmux)
	config := Config{TmuxBinary: proxy, PiBinary: pi, BridgeExtension: filepath.Join(root, "bridge.ts"), DaemonEndpoint: filepath.Join(root, "daemon.sock"), CredentialFile: filepath.Join(root, "credential.json"), ServerName: server, TmuxConfig: configPath, ProjectDirectory: root, StateDirectory: filepath.Join(root, "state"), SessionID: "session", GenerationID: "generation", CallerIdentity: "hosted:agent", TrustProject: true}
	spec := application.HostedPiLaunchSpec{AgentID: "agent", RuntimeID: "malformed-runtime", Incarnation: 1, TmuxSession: "malformed-name", TmuxWindow: "pi", PiSessionDirectory: filepath.Join(root, "sessions"), PiSessionName: "pi"}
	if _, err := (&Runtime{Config: config}).Start(context.Background(), spec); !errors.Is(err, application.ErrHostedOwnershipIndeterminate) {
		t.Fatalf("malformed successful creation was not indeterminate: %v", err)
	}
	recordPath := filepath.Join(config.StateDirectory, runtimeRecordName(spec.RuntimeID)+".json")
	lockPath := filepath.Join(config.StateDirectory, "."+runtimeRecordName(spec.RuntimeID)+".lock")
	if _, err := os.Stat(recordPath); err != nil {
		t.Fatalf("partial fail-closed record missing: %v", err)
	}
	if _, err := os.Stat(lockPath); err != nil {
		t.Fatalf("reservation missing: %v", err)
	}
	if _, err := (&Runtime{Config: config}).Start(context.Background(), spec); !errors.Is(err, ErrRuntimeAlreadyExists) {
		t.Fatalf("retry created a duplicate: %v", err)
	}
	if err := exec.Command(tmux, "-L", server, "has-session", "-t", spec.TmuxSession).Run(); err != nil {
		t.Fatal("indeterminate tmux ownership was silently removed")
	}
	_ = exec.Command(tmux, "-L", server, "kill-server").Run()
}

func TestPublishedRecordFailureRollsBackExactlyOrRetainsReservation(t *testing.T) {
	for _, removalFailure := range []bool{false, true} {
		t.Run(fmt.Sprintf("removal-failure-%t", removalFailure), func(t *testing.T) {
			tmux, err := exec.LookPath("tmux")
			if err != nil {
				t.Skip("tmux unavailable")
			}
			root := t.TempDir()
			_ = os.Chmod(root, 0o700)
			tmuxTmp, _ := os.MkdirTemp("/tmp", "ws-hp-published-")
			t.Cleanup(func() { _ = os.RemoveAll(tmuxTmp) })
			t.Setenv("TMUX_TMPDIR", tmuxTmp)
			server, configPath := fmt.Sprintf("ws-hosted-published-%t", removalFailure), filepath.Join(root, "tmux.conf")
			_ = os.WriteFile(configPath, []byte("set -g pane-base-index 1\n"), 0o600)
			pi := buildSleepingPi(t, root)
			config := Config{TmuxBinary: tmux, PiBinary: pi, BridgeExtension: filepath.Join(root, "bridge.ts"), DaemonEndpoint: filepath.Join(root, "daemon.sock"), CredentialFile: filepath.Join(root, "credential.json"), ServerName: server, TmuxConfig: configPath, ProjectDirectory: root, StateDirectory: filepath.Join(root, "state"), SessionID: "session", GenerationID: "generation", CallerIdentity: "hosted:agent", TrustProject: true}
			spec := application.HostedPiLaunchSpec{AgentID: "agent", RuntimeID: "published-runtime", Incarnation: 1, TmuxSession: "published-name", TmuxWindow: "pi", PiSessionDirectory: filepath.Join(root, "sessions"), PiSessionName: "pi"}
			runtime := &Runtime{Config: config}
			runtime.writeRecord = func(path string, value any) error {
				encoded, err := json.Marshal(value)
				if err != nil {
					return err
				}
				temporary, err := os.CreateTemp(filepath.Dir(path), ".rename-test-")
				if err != nil {
					return err
				}
				name := temporary.Name()
				if err := temporary.Chmod(0o600); err != nil {
					return err
				}
				if _, err := temporary.Write(append(encoded, '\n')); err != nil {
					return err
				}
				if err := temporary.Sync(); err != nil {
					return err
				}
				if err := temporary.Close(); err != nil {
					return err
				}
				if err := os.Rename(name, path); err != nil {
					return err
				}
				return errors.New("forced directory fsync failure after successful rename")
			}
			if removalFailure {
				runtime.removeRecord = func(string) error { return errors.New("forced removal failure") }
			}
			_, startErr := runtime.Start(context.Background(), spec)
			if removalFailure && !errors.Is(startErr, application.ErrHostedOwnershipIndeterminate) {
				t.Fatalf("removal uncertainty not indeterminate: %v", startErr)
			}
			if !removalFailure && (startErr == nil || errors.Is(startErr, application.ErrHostedOwnershipIndeterminate)) {
				t.Fatalf("exact published rollback was not definitive: %v", startErr)
			}
			if err := exec.Command(tmux, "-L", server, "has-session", "-t", spec.TmuxSession).Run(); err == nil {
				t.Fatal("exact rollback orphaned tmux")
			}
			recordPath := filepath.Join(config.StateDirectory, runtimeRecordName(spec.RuntimeID)+".json")
			lockPath := filepath.Join(config.StateDirectory, "."+runtimeRecordName(spec.RuntimeID)+".lock")
			if removalFailure {
				if _, err := os.Stat(recordPath); err != nil {
					t.Fatal("uncertain record not retained")
				}
				if _, err := os.Stat(lockPath); err != nil {
					t.Fatal("uncertain reservation not retained")
				}
				if _, err := (&Runtime{Config: config}).Start(context.Background(), spec); !errors.Is(err, ErrRuntimeAlreadyExists) {
					t.Fatalf("uncertain retry did not fail closed: %v", err)
				}
			} else {
				if _, err := os.Stat(recordPath); !os.IsNotExist(err) {
					t.Fatal("exact record was not removed")
				}
				process, err := (&Runtime{Config: config}).Start(context.Background(), spec)
				if err != nil {
					t.Fatalf("definitive retry failed: %v", err)
				}
				stopCtx, cancel := context.WithTimeout(context.Background(), time.Second)
				defer cancel()
				if err := process.Stop(stopCtx); err != nil {
					t.Fatal(err)
				}
			}
			_ = exec.Command(tmux, "-L", server, "kill-server").Run()
		})
	}
}

func TestRuntimeSecureDirectoryCreationDoesNotMutateThroughSymlink(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(root, "target")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	runtime := &Runtime{Config: Config{TmuxBinary: "/does/not/run", PiBinary: "/pi", BridgeExtension: "/bridge", DaemonEndpoint: "ws://127.0.0.1:17213/actors", CredentialFile: "/credential", ProjectDirectory: root, StateDirectory: filepath.Join(link, "state"), SessionID: "session", GenerationID: "generation", CallerIdentity: "hosted:agent"}}
	spec := application.HostedPiLaunchSpec{AgentID: "agent", RuntimeID: "runtime", Incarnation: 1, TmuxSession: "session", TmuxWindow: "pi", PiSessionDirectory: filepath.Join(root, "sessions"), PiSessionName: "pi"}
	if _, err := runtime.Start(context.Background(), spec); err == nil {
		t.Fatal("symlinked state path was accepted")
	}
	if _, err := os.Stat(filepath.Join(target, "state")); !os.IsNotExist(err) {
		t.Fatal("directory creation mutated through a symlink before rejection")
	}
}

func TestRuntimeStartHonorsHangingTmuxCancellation(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	hanging := buildSleepingPi(t, root)
	runtime := &Runtime{Config: Config{TmuxBinary: hanging, PiBinary: "/pi", BridgeExtension: "/bridge", DaemonEndpoint: "ws://127.0.0.1:17213/actors", CredentialFile: "/credential", ProjectDirectory: root, StateDirectory: filepath.Join(root, "state"), SessionID: "session", GenerationID: "generation", CallerIdentity: "hosted:agent"}}
	spec := application.HostedPiLaunchSpec{AgentID: "agent", RuntimeID: "runtime", Incarnation: 1, TmuxSession: "session", TmuxWindow: "pi", PiSessionDirectory: filepath.Join(root, "sessions"), PiSessionName: "pi"}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	started := time.Now()
	if _, err := runtime.Start(ctx, spec); err == nil {
		t.Fatal("hanging tmux ignored cancellation")
	}
	if time.Since(started) > time.Second {
		t.Fatal("hanging tmux teardown exceeded context bound")
	}
}

func indexOf(values []string, target string) int {
	for index, value := range values {
		if value == target {
			return index
		}
	}
	return -1
}

func equalStrings(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}
