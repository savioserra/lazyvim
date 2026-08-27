package tools

import (
	"os"
	"strings"
	"testing"
)

func TestClientLauncherDetachesDaemonFromInvokingShell(t *testing.T) {
	content, err := os.ReadFile("source-client.sh")
	if err != nil {
		t.Fatal(err)
	}
	script := string(content)
	if !strings.Contains(script, "need setsid;need nohup;private_dirs") {
		t.Fatal("client launcher must require both setsid and nohup before daemon start")
	}
	launch := "setsid nohup env XDG_RUNTIME_DIR=\"$root/run\" XDG_STATE_HOME=\"$root/xdg-state\" XDG_CONFIG_HOME=\"$root/xdg-config\" \"$root/bin/subagents\" -config \"$config\" -socket \"$socket\" </dev/null >\"$root/daemon.log\" 2>&1 &"
	if !strings.Contains(script, launch) {
		t.Fatal("client daemon launch must start a new session before installing nohup semantics and must not inherit stdin/stdout/stderr")
	}
}
