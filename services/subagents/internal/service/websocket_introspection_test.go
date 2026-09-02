package service

import (
	"context"
	"path/filepath"
	"testing"
)

func TestStartWebSocketConfiguredInitializesManagedIntrospectionRunner(t *testing.T) {
	root := t.TempDir()
	daemon, err := StartWebSocketConfigured(context.Background(), "127.0.0.1:0", HostedAdminConfig{
		Enabled:                 true,
		TmuxBinary:              "/tmux",
		PiBinary:                "/pi",
		BridgeExtension:         "/bridge.ts",
		StateDirectory:          filepath.Join(root, "state"),
		PiSessionDirectory:      filepath.Join(root, "sessions"),
		CredentialDirectory:     filepath.Join(root, "credentials"),
		AdminCredentialFile:     filepath.Join(root, "admin", "credential.json"),
		DefaultProjectDirectory: root,
		IntrospectionModel:      "openai-codex/gpt-5.6-sol",
	})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = daemon.Stop(context.Background()) }()
	if daemon.introspectionRunner == nil {
		t.Fatal("production WebSocket startup omitted the managed introspection runner")
	}
}
