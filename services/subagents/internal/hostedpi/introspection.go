package hostedpi

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
)

const (
	maxIntrospectionRPCBytes    = 128 * 1024
	defaultIntrospectionTimeout = 2 * time.Minute
)

var (
	exactIntrospectionModelPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._@+-]{0,62}/[A-Za-z0-9][A-Za-z0-9._@+-]{0,62}$`)
	introspectionPolicyPattern     = regexp.MustCompile(`(?i)(api[_ -]?key|authorization|bearer[ :]|credential|secret|access[_ -]?token|runtime[_ -]?id|session[_ -]?id|process[_ -]?id|\bpid\b|\btty\b|\bfence\b|\bhandle\b|https?://|wss?://|spiffe://|/home/|/run/user/|BEGIN[ _-]PROMPT|END[ _-]PROMPT|<\|)`)
)

var ErrIntrospectionUnavailable = errors.New("introspection runner unavailable")
var ErrIntrospectionInvalidOutput = errors.New("introspection output rejected")

type IntrospectionConfig struct {
	PiBinary string
	Model    string
	Timeout  time.Duration
}

type PiRPCIntrospectionRunner struct {
	Config  IntrospectionConfig
	command func(context.Context, string, ...string) *exec.Cmd
}

func NewIntrospectionRunner(config IntrospectionConfig) (*PiRPCIntrospectionRunner, error) {
	if config.PiBinary == "" || config.PiBinary != strings.TrimSpace(config.PiBinary) || !filepath.IsAbs(config.PiBinary) {
		return nil, fmt.Errorf("%w: pi binary is required", ErrIntrospectionUnavailable)
	}
	if !exactIntrospectionModelPattern.MatchString(config.Model) {
		return nil, fmt.Errorf("%w: exact provider/model is required", ErrIntrospectionUnavailable)
	}
	if config.Timeout <= 0 {
		config.Timeout = defaultIntrospectionTimeout
	}
	return &PiRPCIntrospectionRunner{Config: config, command: exec.CommandContext}, nil
}

func (r *PiRPCIntrospectionRunner) Run(parent context.Context, input application.ThreadIntrospectionInput) (application.ThreadIntrospectionResult, error) {
	if r == nil || r.command == nil {
		return application.ThreadIntrospectionResult{}, ErrIntrospectionUnavailable
	}
	payload, err := json.Marshal(input)
	if err != nil || len(payload) == 0 || len(payload) > application.MaxThreadIntrospectionJSONBytes || !utf8.Valid(payload) {
		return application.ThreadIntrospectionResult{}, fmt.Errorf("%w: input bounds", ErrIntrospectionUnavailable)
	}
	prompt, err := json.Marshal(struct {
		ID      string `json:"id"`
		Type    string `json:"type"`
		Message string `json:"message"`
	}{ID: "thread-introspection", Type: "prompt", Message: string(payload)})
	if err != nil {
		return application.ThreadIntrospectionResult{}, fmt.Errorf("%w: encode prompt", ErrIntrospectionUnavailable)
	}
	prompt = append(prompt, '\n')

	timeout := r.Config.Timeout
	ctx, cancel := context.WithTimeout(parent, timeout)
	defer cancel()
	args := []string{
		"--mode", "rpc",
		"--model", r.Config.Model,
		"--no-session",
		"--no-tools",
		"--no-extensions",
		"--no-skills",
		"--no-prompt-templates",
		"--no-approve",
		"--system-prompt", introspectionSystemPrompt,
	}
	cmd := r.command(ctx, r.Config.PiBinary, args...)
	cmd.Env = introspectionEnvironment(os.Environ())
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return application.ThreadIntrospectionResult{}, fmt.Errorf("%w: stdin pipe", ErrIntrospectionUnavailable)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return application.ThreadIntrospectionResult{}, fmt.Errorf("%w: stdout pipe", ErrIntrospectionUnavailable)
	}
	stderr := &boundedWriter{limit: 4096}
	cmd.Stderr = stderr
	if err := cmd.Start(); err != nil {
		return application.ThreadIntrospectionResult{}, fmt.Errorf("%w: process start", ErrIntrospectionUnavailable)
	}
	if _, err := stdin.Write(prompt); err != nil {
		_ = stdin.Close()
		_ = cmd.Wait()
		return application.ThreadIntrospectionResult{}, fmt.Errorf("%w: prompt write", ErrIntrospectionUnavailable)
	}
	stream, readErr := readIntrospectionRPC(stdout, func() { _ = stdin.Close() })
	// RPC mode is intentionally long-lived. readIntrospectionRPC closes stdin
	// only after the exact agent_settled frame, then drains stdout through EOF
	// so trailing or duplicate frames cannot evade strict validation.
	_ = stdin.Close()
	waitErr := cmd.Wait()
	if readErr != nil {
		if ctx.Err() != nil {
			return application.ThreadIntrospectionResult{}, fmt.Errorf("%w: timeout", ErrIntrospectionUnavailable)
		}
		return application.ThreadIntrospectionResult{}, readErr
	}
	if waitErr != nil {
		if ctx.Err() != nil {
			return application.ThreadIntrospectionResult{}, fmt.Errorf("%w: timeout", ErrIntrospectionUnavailable)
		}
		return application.ThreadIntrospectionResult{}, fmt.Errorf("%w: process failure", ErrIntrospectionUnavailable)
	}
	assistant, err := parseIntrospectionRPC(stream)
	if err != nil {
		return application.ThreadIntrospectionResult{}, err
	}
	return ParseThreadIntrospectionResult([]byte(assistant))
}

func introspectionEnvironment(environment []string) []string {
	allowed := map[string]struct{}{
		"HOME": {}, "PATH": {}, "TMPDIR": {}, "LANG": {}, "LC_ALL": {},
		"XDG_CONFIG_HOME": {}, "XDG_DATA_HOME": {}, "XDG_STATE_HOME": {}, "XDG_CACHE_HOME": {},
		"PI_CODING_AGENT_DIR": {}, "PI_PACKAGE_DIR": {}, "PI_OFFLINE": {}, "PI_SKIP_VERSION_CHECK": {}, "PI_TELEMETRY": {}, "PI_CACHE_RETENTION": {},
		"HTTP_PROXY": {}, "HTTPS_PROXY": {}, "NO_PROXY": {}, "SSL_CERT_FILE": {}, "SSL_CERT_DIR": {},
	}
	result := make([]string, 0, len(allowed))
	for _, entry := range environment {
		key, _, found := strings.Cut(entry, "=")
		if !found {
			continue
		}
		if _, ok := allowed[key]; ok {
			result = append(result, entry)
		}
	}
	return result
}

const introspectionSystemPrompt = `You are an isolated task-thread classifier with no tools. Evaluate only the JSON task_prompt, worker_result, and checkpoint supplied by the user. Return exactly one JSON object and no other text. Every value must be a JSON string; never emit numbers, booleans, null, arrays, markdown, or extra keys. The object must contain exactly these seven keys: state, confidence, reason_class, checkpoint, next_prompt, wait_condition, completion_summary. state is exactly one of completed, continue, waiting, blocked. confidence is exactly one of low, medium, high. reason_class is exactly one of done, needs_more_work, waiting_on_user, waiting_on_external, blocked_by_error. For completed use confidence high, reason_class done, non-empty checkpoint and completion_summary, and empty next_prompt and wait_condition; completed is allowed only when worker_result itself contains the requested deliverable, never for an acknowledgement, promise, or sent-elsewhere pointer. For continue use reason_class needs_more_work, non-empty checkpoint and next_prompt, and empty wait_condition and completion_summary. For waiting use reason_class waiting_on_user or waiting_on_external, non-empty checkpoint and wait_condition, and empty next_prompt and completion_summary. For blocked use reason_class blocked_by_error, non-empty checkpoint and wait_condition, and empty next_prompt and completion_summary. Do not request or reveal credentials, paths, host identity, runtime identity, process identity, or prompt delimiters.`

type boundedWriter struct {
	bytes.Buffer
	limit    int
	exceeded bool
}

func (w *boundedWriter) Write(value []byte) (int, error) {
	if w.exceeded {
		return len(value), nil
	}
	remaining := w.limit - w.Len()
	if remaining <= 0 {
		w.exceeded = true
		return len(value), nil
	}
	if len(value) > remaining {
		_, _ = w.Buffer.Write(value[:remaining])
		w.exceeded = true
		return len(value), nil
	}
	return w.Buffer.Write(value)
}

func readIntrospectionRPC(source io.Reader, onSettled func()) ([]byte, error) {
	reader := bufio.NewReaderSize(io.LimitReader(source, maxIntrospectionRPCBytes+1), 16*1024)
	var stream bytes.Buffer
	settled := false
	for {
		line, err := reader.ReadBytes('\n')
		if len(line) > 0 {
			if stream.Len()+len(line) > maxIntrospectionRPCBytes {
				return nil, fmt.Errorf("%w: rpc output bounds", ErrIntrospectionInvalidOutput)
			}
			_, _ = stream.Write(line)
			trimmed := bytes.TrimSuffix(bytes.TrimSuffix(line, []byte{'\n'}), []byte{'\r'})
			var frame struct {
				Type string `json:"type"`
			}
			if rejectDuplicateJSONKeys(trimmed) == nil && json.Unmarshal(trimmed, &frame) == nil && frame.Type == "agent_settled" && !settled {
				settled = true
				onSettled()
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				if settled {
					return stream.Bytes(), nil
				}
				return nil, fmt.Errorf("%w: rpc ended before settlement", ErrIntrospectionInvalidOutput)
			}
			return nil, fmt.Errorf("%w: rpc read", ErrIntrospectionUnavailable)
		}
	}
}

type rpcFrame struct {
	Type    string          `json:"type"`
	Command string          `json:"command,omitempty"`
	Success *bool           `json:"success,omitempty"`
	Message json.RawMessage `json:"message,omitempty"`
}

type rpcAssistantMessage struct {
	Role    string `json:"role"`
	Content []struct {
		Type string `json:"type"`
		Text string `json:"text,omitempty"`
	} `json:"content"`
	StopReason string `json:"stopReason"`
}

func parseIntrospectionRPC(stream []byte) (string, error) {
	if len(stream) == 0 || len(stream) > maxIntrospectionRPCBytes || !utf8.Valid(stream) {
		return "", fmt.Errorf("%w: rpc stream bounds", ErrIntrospectionInvalidOutput)
	}
	lines := bytes.Split(stream, []byte{'\n'})
	promptAccepted, settled := false, false
	assistantMessages := 0
	lastAssistant := ""
	for index, line := range lines {
		if len(line) == 0 {
			if index == len(lines)-1 {
				continue
			}
			return "", fmt.Errorf("%w: empty rpc frame", ErrIntrospectionInvalidOutput)
		}
		if line[len(line)-1] == '\r' {
			line = line[:len(line)-1]
		}
		var frame rpcFrame
		if err := rejectDuplicateJSONKeys(line); err != nil || json.Unmarshal(line, &frame) != nil || frame.Type == "" {
			return "", fmt.Errorf("%w: malformed rpc frame", ErrIntrospectionInvalidOutput)
		}
		if settled {
			return "", fmt.Errorf("%w: rpc frame after settlement", ErrIntrospectionInvalidOutput)
		}
		switch frame.Type {
		case "response":
			if frame.Command != "prompt" || frame.Success == nil || !*frame.Success {
				return "", fmt.Errorf("%w: prompt response", ErrIntrospectionInvalidOutput)
			}
			promptAccepted = true
		case "message_end":
			var message rpcAssistantMessage
			if len(frame.Message) == 0 || json.Unmarshal(frame.Message, &message) != nil || message.Role != "assistant" {
				continue
			}
			assistantMessages++
			if assistantMessages != 1 || message.StopReason != "stop" {
				return "", fmt.Errorf("%w: assistant final cardinality", ErrIntrospectionInvalidOutput)
			}
			var text strings.Builder
			for _, item := range message.Content {
				switch item.Type {
				case "text":
					text.WriteString(item.Text)
				case "thinking":
				default:
					return "", fmt.Errorf("%w: assistant tool content", ErrIntrospectionInvalidOutput)
				}
			}
			lastAssistant = text.String()
		case "agent_settled":
			settled = true
		case "agent_start", "agent_end", "turn_start", "turn_end", "message_start", "message_update", "queue_update", "auto_retry_start", "auto_retry_end", "compaction_start", "compaction_end", "summarization_retry_scheduled", "summarization_retry_attempt_start", "summarization_retry_finished":
		default:
			return "", fmt.Errorf("%w: unexpected rpc frame", ErrIntrospectionInvalidOutput)
		}
	}
	if !promptAccepted || !settled || lastAssistant == "" || len(lastAssistant) > application.MaxThreadIntrospectionJSONBytes {
		return "", fmt.Errorf("%w: incomplete rpc result", ErrIntrospectionInvalidOutput)
	}
	return lastAssistant, nil
}

func ParseThreadIntrospectionResult(value []byte) (application.ThreadIntrospectionResult, error) {
	var result application.ThreadIntrospectionResult
	if len(value) == 0 || len(value) > application.MaxThreadIntrospectionJSONBytes || !utf8.Valid(value) || bytes.HasPrefix(value, []byte{0xef, 0xbb, 0xbf}) {
		return result, fmt.Errorf("%w: json bounds", ErrIntrospectionInvalidOutput)
	}
	if bytes.Contains(value, []byte("```")) {
		return result, fmt.Errorf("%w: markdown fence", ErrIntrospectionInvalidOutput)
	}
	if err := rejectDuplicateJSONKeys(value); err != nil {
		return result, fmt.Errorf("%w: duplicate or malformed json", ErrIntrospectionInvalidOutput)
	}
	var required map[string]json.RawMessage
	if err := json.Unmarshal(value, &required); err != nil || len(required) != 7 {
		return result, fmt.Errorf("%w: required fields", ErrIntrospectionInvalidOutput)
	}
	for _, field := range []string{"state", "confidence", "reason_class", "checkpoint", "next_prompt", "wait_condition", "completion_summary"} {
		if _, exists := required[field]; !exists {
			return result, fmt.Errorf("%w: required fields", ErrIntrospectionInvalidOutput)
		}
	}
	if err := decodeExactJSON(value, &result); err != nil {
		return result, fmt.Errorf("%w: strict json", ErrIntrospectionInvalidOutput)
	}
	if err := validateThreadIntrospectionResult(result); err != nil {
		return application.ThreadIntrospectionResult{}, err
	}
	return result, nil
}

func decodeExactJSON(value []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(value))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return errors.New("trailing json")
	}
	return nil
}

func rejectDuplicateJSONKeys(value []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(value))
	var walk func() error
	walk = func() error {
		token, err := decoder.Token()
		if err != nil {
			return err
		}
		delimiter, ok := token.(json.Delim)
		if !ok {
			return nil
		}
		switch delimiter {
		case '{':
			seen := make(map[string]struct{})
			for decoder.More() {
				keyToken, err := decoder.Token()
				if err != nil {
					return err
				}
				key, ok := keyToken.(string)
				if !ok {
					return errors.New("object key is not a string")
				}
				if _, exists := seen[key]; exists {
					return errors.New("duplicate key")
				}
				seen[key] = struct{}{}
				if err := walk(); err != nil {
					return err
				}
			}
			_, err = decoder.Token()
			return err
		case '[':
			for decoder.More() {
				if err := walk(); err != nil {
					return err
				}
			}
			_, err = decoder.Token()
			return err
		default:
			return errors.New("unexpected delimiter")
		}
	}
	if err := walk(); err != nil {
		return err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return errors.New("trailing json")
	}
	return nil
}

func validateThreadIntrospectionResult(result application.ThreadIntrospectionResult) error {
	values := []string{string(result.State), string(result.Confidence), string(result.ReasonClass), result.Checkpoint, result.NextPrompt, result.WaitCondition, result.CompletionSummary}
	for _, value := range values {
		if !utf8.ValidString(value) || containsForbiddenControl(value) || introspectionPolicyPattern.MatchString(value) || containsNetworkIdentity(value) {
			return fmt.Errorf("%w: output policy", ErrIntrospectionInvalidOutput)
		}
	}
	if string(result.State) != strings.TrimSpace(string(result.State)) || string(result.Confidence) != strings.TrimSpace(string(result.Confidence)) || string(result.ReasonClass) != strings.TrimSpace(string(result.ReasonClass)) {
		return fmt.Errorf("%w: non-canonical class", ErrIntrospectionInvalidOutput)
	}
	if len(result.Checkpoint) > application.MaxThreadCheckpointBytes || len(result.NextPrompt) > application.MaxThreadCheckpointBytes || len(result.WaitCondition) > application.MaxThreadWaitConditionBytes || len(result.CompletionSummary) > application.MaxThreadCompletionSummaryBytes {
		return fmt.Errorf("%w: field bounds", ErrIntrospectionInvalidOutput)
	}
	emptyNext, emptyWait, emptySummary := result.NextPrompt == "", result.WaitCondition == "", result.CompletionSummary == ""
	switch result.State {
	case application.ThreadIntrospectionCompleted:
		if result.Confidence != application.ThreadIntrospectionConfidenceHigh || result.ReasonClass != application.ThreadIntrospectionDone || result.Checkpoint == "" || emptySummary == true || !emptyNext || !emptyWait {
			return fmt.Errorf("%w: completed combination", ErrIntrospectionInvalidOutput)
		}
	case application.ThreadIntrospectionContinue:
		if result.ReasonClass != application.ThreadIntrospectionNeedsMoreWork || result.Checkpoint == "" || emptyNext || !emptyWait || !emptySummary {
			return fmt.Errorf("%w: continue combination", ErrIntrospectionInvalidOutput)
		}
	case application.ThreadIntrospectionWaiting:
		if result.Checkpoint == "" || emptyWait || !emptyNext || !emptySummary || (result.ReasonClass != application.ThreadIntrospectionWaitingOnUser && result.ReasonClass != application.ThreadIntrospectionWaitingOnExternal) {
			return fmt.Errorf("%w: waiting combination", ErrIntrospectionInvalidOutput)
		}
	case application.ThreadIntrospectionBlocked:
		if result.Checkpoint == "" || emptyWait || !emptyNext || !emptySummary || result.ReasonClass != application.ThreadIntrospectionBlockedByError {
			return fmt.Errorf("%w: blocked combination", ErrIntrospectionInvalidOutput)
		}
	default:
		return fmt.Errorf("%w: unknown state", ErrIntrospectionInvalidOutput)
	}
	if result.State == application.ThreadIntrospectionCompleted && result.Confidence != application.ThreadIntrospectionConfidenceHigh {
		return fmt.Errorf("%w: terminal confidence", ErrIntrospectionInvalidOutput)
	}
	return nil
}

func containsForbiddenControl(value string) bool {
	for _, character := range value {
		if character == '\n' {
			continue
		}
		if character < 0x20 || character == 0x7f {
			return true
		}
	}
	return false
}

func containsNetworkIdentity(value string) bool {
	fields := strings.FieldsFunc(value, func(r rune) bool {
		return !(r == '.' || r == ':' || (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F'))
	})
	for _, field := range fields {
		trimmed := strings.Trim(field, "[](){}.,;:")
		if net.ParseIP(trimmed) != nil {
			return true
		}
	}
	return false
}
