package remoting

import (
	"reflect"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/remote"
)

func TestPublicAgentSerializersRoundTripAndNoCredential(t *testing.T) {
	config := remote.NewConfig("127.0.0.1", 1, PublicAgentSerializers()...)
	messages := []any{
		&application.RemoteHostedPlacement{OperationID: "op", DedupeID: "dedupe", DeadlineUnixMillis: time.Now().Add(time.Minute).UnixMilli(), AgentID: "ui_remote_qa", ProjectDirectory: "/tmp/project", DisplayName: "QA", Role: "qa", TrustProject: true},
		&application.RemoteHostedPlacementResult{Accepted: true, AgentID: "ui_remote_qa", ActorName: "agent-1", Reference: application.AgentReference{AgentID: "ui_remote_qa", LifecycleRevision: 1, AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned}, HostedPiRuntime: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeReady}}},
		&application.ListPublicHostedAgents{Limit: 8},
		&application.ListPublicHostedAgentsResult{Agents: []application.PublicHostedAgent{{AgentID: "ui_remote_qa", ActorName: "agent-1", Reference: application.AgentReference{AgentID: "ui_remote_qa"}}}},
		&application.PublicHostedAgent{AgentID: "ui_remote_qa", ActorName: "agent-1", Reference: application.AgentReference{AgentID: "ui_remote_qa"}},
		&application.RemoteAttachAgent{SessionID: "s", GenerationID: "g", Principal: "pm", AgentID: "ui_remote_qa", RequestedCapabilities: []string{"observe", "prompt"}, IssuedHandle: "h"},
		&application.AttachResult{Completed: true, Handle: "h", Fence: 1},
		&application.RemoteBridgeIntent{SessionID: "s", GenerationID: "g", Principal: "pm", Handle: "h", SourceAgentID: "client", TargetAgentID: "ui_remote_qa", RequestID: "r", RequiredCapability: "prompt", DedupeID: "d", ChainID: "c", Fence: 1, SourceMutationSequence: 1, Deadline: time.Now().Add(time.Minute), HopLimit: 8, Mode: application.BridgeMessagePrompt, Payload: []byte("prompt")},
		&application.BridgeIntentResult{Accepted: true, Completed: true, Result: []byte("answer")},
	}
	for _, message := range messages {
		if hasCredentialField(reflect.TypeOf(message)) {
			t.Fatalf("actor-plane message contains credential-like field: %T", message)
		}
		serializer := config.Serializer(message)
		encoded, err := serializer.Serialize(message)
		if err != nil {
			t.Fatalf("serialize %T: %v", message, err)
		}
		decoded, err := serializer.Deserialize(encoded)
		if err != nil {
			t.Fatalf("deserialize %T: %v", message, err)
		}
		if reflect.TypeOf(decoded) != reflect.TypeOf(message) {
			t.Fatalf("decoded type mismatch: got %T want %T", decoded, message)
		}
	}
}

func hasCredentialField(t reflect.Type) bool {
	if t.Kind() == reflect.Pointer {
		t = t.Elem()
	}
	for i := 0; i < t.NumField(); i++ {
		name := t.Field(i).Name
		if name == "Credential" || name == "AdminCredential" || name == "SessionCredential" {
			return true
		}
	}
	return false
}
