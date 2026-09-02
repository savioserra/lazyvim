package hostedpi

import (
	"context"
	"errors"
	"os/exec"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

const validCompletedIntrospection = `{"state":"completed","confidence":"high","reason_class":"done","checkpoint":"deliverable verified","next_prompt":"","wait_condition":"","completion_summary":"implemented and tested"}`

func TestParseThreadIntrospectionResultStrictSchema(t *testing.T) {
	tests := []struct {
		name, value string
		accepted    bool
	}{
		{name: "completed", value: validCompletedIntrospection, accepted: true},
		{name: "generic security concepts", value: strings.Replace(validCompletedIntrospection, "deliverable verified", "authorization fencing and credential isolation were verified", 1), accepted: true},
		{name: "continue", value: `{"state":"continue","confidence":"medium","reason_class":"needs_more_work","checkpoint":"tests still fail","next_prompt":"fix remaining tests","wait_condition":"","completion_summary":""}`, accepted: true},
		{name: "waiting", value: `{"state":"waiting","confidence":"medium","reason_class":"waiting_on_user","checkpoint":"choice required","next_prompt":"","wait_condition":"user chooses option","completion_summary":""}`, accepted: true},
		{name: "blocked", value: `{"state":"blocked","confidence":"low","reason_class":"blocked_by_error","checkpoint":"dependency unavailable","next_prompt":"","wait_condition":"dependency becomes available","completion_summary":""}`, accepted: true},
		{name: "duplicate", value: `{"state":"completed","state":"continue","confidence":"high","reason_class":"done","checkpoint":"x","next_prompt":"","wait_condition":"","completion_summary":"x"}`},
		{name: "extra", value: strings.TrimSuffix(validCompletedIntrospection, "}") + `,"model":"hidden"}`},
		{name: "missing", value: `{"state":"completed","confidence":"high","reason_class":"done","checkpoint":"x","next_prompt":"","wait_condition":""}`},
		{name: "trailing", value: validCompletedIntrospection + ` {}`},
		{name: "markdown", value: "```json\n" + validCompletedIntrospection + "\n```"},
		{name: "bom", value: "\ufeff" + validCompletedIntrospection},
		{name: "oversize checkpoint", value: strings.Replace(validCompletedIntrospection, "deliverable verified", strings.Repeat("x", application.MaxThreadCheckpointBytes+1), 1)},
		{name: "low terminal", value: strings.Replace(validCompletedIntrospection, `"confidence":"high"`, `"confidence":"low"`, 1)},
		{name: "wrong terminal class", value: strings.Replace(validCompletedIntrospection, `"reason_class":"done"`, `"reason_class":"needs_more_work"`, 1)},
		{name: "policy runtime identity", value: strings.Replace(validCompletedIntrospection, "deliverable verified", "runtime_id=raw-runtime", 1)},
		{name: "policy authorization value", value: strings.Replace(validCompletedIntrospection, "deliverable verified", "authorization=raw-token", 1)},
		{name: "policy fence value", value: strings.Replace(validCompletedIntrospection, "deliverable verified", "fence=secret-value", 1)},
		{name: "policy credential path", value: strings.Replace(validCompletedIntrospection, "deliverable verified", "credential at /home/operator/auth.json", 1)},
		{name: "policy host", value: strings.Replace(validCompletedIntrospection, "deliverable verified", "host 127.0.0.1 verified", 1)},
		{name: "control", value: strings.Replace(validCompletedIntrospection, "deliverable verified", `bad\u0001text`, 1)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			result, err := ParseThreadIntrospectionResult([]byte(test.value))
			if test.accepted && err != nil {
				t.Fatalf("valid result rejected: %v", err)
			}
			if !test.accepted && !errors.Is(err, ErrIntrospectionInvalidOutput) {
				t.Fatalf("invalid result did not fail closed: %#v, %v", result, err)
			}
		})
	}
	invalidUTF8 := append([]byte(nil), []byte(validCompletedIntrospection)...)
	invalidUTF8[len(invalidUTF8)/2] = 0xff
	if _, err := ParseThreadIntrospectionResult(invalidUTF8); !errors.Is(err, ErrIntrospectionInvalidOutput) {
		t.Fatalf("invalid UTF-8 was accepted: %v", err)
	}
}

func TestIntrospectionRunnerUsesIsolatedExactModelRPC(t *testing.T) {
	t.Setenv("WS_SUBAGENTS_CREDENTIAL_FILE", "/run/user/credential.json")
	t.Setenv("OPENAI_API_KEY", "must-not-be-inherited")
	var gotBinary string
	var gotArgs []string
	var spawned *exec.Cmd
	runner, err := NewIntrospectionRunner(IntrospectionConfig{PiBinary: "/managed/pi", Model: "openai-codex/gpt-5.6-sol", Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	runner.command = func(ctx context.Context, binary string, args ...string) *exec.Cmd {
		gotBinary, gotArgs = binary, append([]string(nil), args...)
		output := `{"id":"thread-introspection","type":"response","command":"prompt","success":true}` + "\n" +
			`{"type":"agent_start"}` + "\n" +
			`{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":` + shellSingleQuoteJSON(validCompletedIntrospection) + `}],"stopReason":"stop"}}` + "\n" +
			`{"type":"agent_end","messages":[],"willRetry":false}` + "\n" +
			`{"type":"agent_settled"}` + "\n"
		spawned = exec.CommandContext(ctx, "/bin/sh", "-c", "IFS= read -r prompt; test -n \"$prompt\"; printf %s "+shellQuote(output)+"; cat >/dev/null")
		return spawned
	}
	result, err := runner.Run(context.Background(), application.ThreadIntrospectionInput{TaskPrompt: "implement thread scheduler", WorkerResult: "implemented and tested", Checkpoint: "ready"})
	if err != nil {
		t.Fatal(err)
	}
	if result.State != application.ThreadIntrospectionCompleted || gotBinary != "/managed/pi" {
		t.Fatalf("unexpected runner result/config: %#v %q", result, gotBinary)
	}
	for _, required := range []string{"--mode", "rpc", "--model", "openai-codex/gpt-5.6-sol", "--no-session", "--no-tools", "--no-extensions", "--no-skills", "--no-prompt-templates", "--no-approve", "--system-prompt"} {
		if !slices.Contains(gotArgs, required) {
			t.Fatalf("isolated runner omitted %q: %q", required, gotArgs)
		}
	}
	systemPromptIndex := slices.Index(gotArgs, "--system-prompt")
	if systemPromptIndex < 0 || systemPromptIndex+1 >= len(gotArgs) || !strings.Contains(gotArgs[systemPromptIndex+1], "Every value must be a JSON string") || !strings.Contains(gotArgs[systemPromptIndex+1], "confidence is exactly one of low, medium, high") || !strings.Contains(gotArgs[systemPromptIndex+1], "blocked_by_error") {
		t.Fatalf("isolated classifier prompt omitted the strict literal schema: %q", gotArgs)
	}
	if spawned == nil || !slices.ContainsFunc(spawned.Env, func(value string) bool { return strings.HasPrefix(value, "HOME=") }) {
		t.Fatalf("runner did not preserve owner Pi home: %q", spawned.Env)
	}
	for _, value := range spawned.Env {
		if strings.HasPrefix(value, "WS_SUBAGENTS_") || strings.HasPrefix(value, "OPENAI_API_KEY=") || strings.HasPrefix(value, "TMUX=") || strings.HasPrefix(value, "SSH_AUTH_SOCK=") {
			t.Fatalf("runner inherited non-Pi credential/control environment: %q", value)
		}
	}
}

func TestIntrospectionRunnerFailsClosedOnTimeoutAndInvalidModel(t *testing.T) {
	for _, model := range []string{"", "worker", "gpt-5.6-sol", "provider/family/model", " provider/model"} {
		if _, err := NewIntrospectionRunner(IntrospectionConfig{PiBinary: "/pi", Model: model}); !errors.Is(err, ErrIntrospectionUnavailable) {
			t.Fatalf("invalid model %q was accepted: %v", model, err)
		}
	}
	runner, err := NewIntrospectionRunner(IntrospectionConfig{PiBinary: "/pi", Model: "provider/model", Timeout: 10 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	runner.command = func(ctx context.Context, _ string, _ ...string) *exec.Cmd {
		return exec.CommandContext(ctx, "/bin/sh", "-c", "cat >/dev/null; sleep 1")
	}
	_, err = runner.Run(context.Background(), application.ThreadIntrospectionInput{TaskPrompt: "task", WorkerResult: "result"})
	if !errors.Is(err, ErrIntrospectionUnavailable) || !strings.Contains(err.Error(), "timeout") {
		t.Fatalf("timeout did not fail closed: %v", err)
	}
}

func TestParseIntrospectionRPCRejectsUnsettledToolAndOversizeStreams(t *testing.T) {
	assistant := `{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":` + shellSingleQuoteJSON(validCompletedIntrospection) + `}],"stopReason":"stop"}}`
	for _, stream := range []string{
		`{"type":"response","command":"prompt","success":true}` + "\n" + assistant + "\n",
		`{"type":"response","command":"prompt","success":true}` + "\n" + `{"type":"tool_execution_start"}` + "\n" + `{"type":"agent_settled"}` + "\n",
		`{"type":"response","command":"prompt","success":false}` + "\n" + `{"type":"agent_settled"}` + "\n",
		`{"type":"response","command":"prompt","success":true}` + "\n" + assistant + "\n" + assistant + "\n" + `{"type":"agent_settled"}` + "\n",
		`{"type":"response","command":"prompt","success":true}` + "\n" + assistant + "\n" + `{"type":"agent_settled"}` + "\n" + `{"type":"agent_end","messages":[],"willRetry":false}` + "\n",
	} {
		if _, err := parseIntrospectionRPC([]byte(stream)); !errors.Is(err, ErrIntrospectionInvalidOutput) {
			t.Fatalf("unsafe RPC stream was accepted: %v", err)
		}
	}
	if _, err := parseIntrospectionRPC([]byte(strings.Repeat("x", maxIntrospectionRPCBytes+1))); !errors.Is(err, ErrIntrospectionInvalidOutput) {
		t.Fatalf("oversize RPC stream was accepted: %v", err)
	}
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

// shellSingleQuoteJSON returns a JSON string literal; its name distinguishes it
// from shellQuote used for the complete mock stdout argument.
func shellSingleQuoteJSON(value string) string {
	quoted := strings.ReplaceAll(value, `\`, `\\`)
	quoted = strings.ReplaceAll(quoted, `"`, `\"`)
	return `"` + quoted + `"`
}
