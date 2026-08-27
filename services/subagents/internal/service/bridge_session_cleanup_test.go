package service

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
)

func TestBridgeSessionActorPostStopRemovesPushRegistryEntry(t *testing.T) {
	root := t.TempDir()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", filepath.Join(root, "control.sock"))
	if err != nil {
		t.Fatal(err)
	}
	daemon, err := startWithListener(context.Background(), listener)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	session := &bridgePushSession{sessionID: "session", generationID: "generation", principal: "principal", agentID: "agent", handle: "handle", fence: 1, writer: make(chan<- *subagentsv1.Envelope), closed: make(chan struct{})}
	daemon.registerBridgePush(session)
	deadline := time.Now().Add(time.Second)
	var pidName string
	for time.Now().Before(deadline) {
		daemon.pushMu.Lock()
		pid := daemon.pushSessions[session]
		if pid != nil {
			pidName = pid.Name()
		}
		daemon.pushMu.Unlock()
		if pidName != "" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if pidName == "" {
		t.Fatal("bridge session actor was not registered")
	}
	pid, err := daemon.system.ActorOf(context.Background(), pidName)
	if err != nil {
		t.Fatal(err)
	}
	if err := pid.Shutdown(context.Background()); err != nil {
		t.Fatal(err)
	}
	deadline = time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		daemon.pushMu.Lock()
		_, exists := daemon.pushSessions[session]
		daemon.pushMu.Unlock()
		if !exists {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("stopped bridge session actor remained in push registry")
}
