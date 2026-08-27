package application

import (
	"context"
	"time"

	"github.com/tochemey/goakt/v4/actor"
)

const DurableHostedSchemaVersion = 2

type DurableHostedSession struct {
	SessionID      string    `json:"session_id"`
	GenerationID   string    `json:"generation_id"`
	Caller         string    `json:"caller"`
	Capabilities   []string  `json:"capabilities"`
	ExpiresAt      time.Time `json:"expires_at"`
	Persistent     bool      `json:"persistent"`
	CredentialFile string    `json:"credential_file"`
}
type DurableRuntimeConfig struct {
	ProjectDirectory string `json:"project_directory"`
	TrustProject     bool   `json:"trust_project"`
}
type DurableAttachment struct {
	SessionID, GenerationID, Principal, Handle string
	Fence                                      uint64
	Capabilities                               []string
}
type DurableMutationResult struct {
	Sequence uint64             `json:"sequence"`
	Digest   [32]byte           `json:"digest"`
	Pending  bool               `json:"pending"`
	Result   BridgeIntentResult `json:"result"`
	DedupeID string             `json:"dedupe_id"`
	ChainID  string             `json:"chain_id"`
}
type DurableMutationScope struct {
	Key, SessionID, GenerationID, Principal string
	Fence, Incarnation, HighWater           uint64
	Results                                 []DurableMutationResult
	Dedupe                                  map[string]DurableDedupeRecord
	Chains                                  []string
}
type DurableDedupeRecord struct {
	Sequence, MutationSequence uint64
	ChainID                    string
}
type DurableAgentState struct {
	Revision, CommandSequence, Fence, BridgeFence, BridgeSequence, BridgeLeaseToken uint64
	BridgeReady, BridgeDeclaredReady                                                bool
	Attachments                                                                     []DurableAttachment
	Revoked                                                                         []string
	BridgeSession, BridgeGeneration, BridgePrincipal, BridgeHandle, BridgePiSession string
	BridgeDeliveries                                                                []BridgeDelivery
	DeliverySources                                                                 map[uint64]string
	MutationScopes                                                                  []DurableMutationScope
}
type DurableHostedRecord struct {
	SchemaVersion       int                    `json:"schema_version"`
	OwnerUID            int                    `json:"owner_uid"`
	AgentID             string                 `json:"agent_id"`
	AuthorityBinding    AuthorityBinding       `json:"authority_binding"`
	AllowedCapabilities []string               `json:"allowed_capabilities"`
	Retention           string                 `json:"retention"`
	Recovery            string                 `json:"recovery"`
	Session             DurableHostedSession   `json:"session"`
	LaunchSpec          HostedPiLaunchSpec     `json:"launch_spec"`
	RuntimeConfig       DurableRuntimeConfig   `json:"runtime_config"`
	Binding             HostedPiRuntimeBinding `json:"binding"`
	AgentState          DurableAgentState      `json:"agent_state"`
}

type DurableStore interface {
	Save(context.Context, DurableHostedRecord) error
	Remove(context.Context, string) error
}
type PersistDurableHostedState struct {
	Record      DurableHostedRecord
	Owner       *actor.PID
	Correlation uint64
}
type DurableHostedStatePersisted struct {
	Correlation uint64
	Err         error
}
type RemoveDurableHostedState struct {
	AgentID     string
	Owner       *actor.PID
	Correlation uint64
}
type DurableHostedStateRemoved struct {
	Correlation uint64
	Err         error
}
type DurableBarrier struct{ Result chan<- OperationResult }
type ConfigureDurableHostedState struct {
	Record         DurableHostedRecord
	PersistencePID *actor.PID
}
