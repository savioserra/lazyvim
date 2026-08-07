package cli

import (
	"bytes"
	"strings"
	"testing"
)

func TestRootHelpListsMigratedCommands(t *testing.T) {
	var output bytes.Buffer
	root := New(strings.NewReader(""), &output, &output)
	root.SetArgs([]string{"--help"})
	if err := root.Execute(); err != nil {
		t.Fatal(err)
	}
	for _, command := range []string{"install", "apply", "capture", "restore", "restore-tmux", "check", "update", "sync", "lock-mason", "downloads"} {
		if !strings.Contains(output.String(), command) {
			t.Fatalf("help omitted %s", command)
		}
	}
}
