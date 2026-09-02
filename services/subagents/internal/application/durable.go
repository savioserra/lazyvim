package application

import (
	"context"
	"time"

	"github.com/tochemey/goakt/v4/actor"
)

const (
	DurableHostedSchemaVersion      = 2
	DurableAgentRuntimeSchemaV3     = 3
	DurableHostedPiBridgeSchemaV1   = 1
	DurableAskCorrelationSchemaV1   = 1
	DurableActorReplyReplaySchemaV1 = 1
)

const (
	DurableRecordKindAgentRuntime     = "agent-runtime"
	DurableRecordKindHostedPiBridge   = "hosted-pi-bridge"
	DurableRecordKindAskCorrelation   = "ask-correlation"
	DurableRecordKindActorReplyReplay = "actor-reply-replay"
)

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
	Key, Token, SessionID, GenerationID, Principal string
	Fence, Incarnation, HighWater                  uint64
	Results                                        []DurableMutationResult
	Dedupe                                         map[string]DurableDedupeRecord
	Chains                                         []string
}
type DurableDedupeRecord struct {
	Sequence, MutationSequence uint64
	ChainID                    string
}
type SourceMutationFingerprint struct {
	RequestID, DedupeID, ChainID, TargetStableID, RequiredCapability string
	SourceMutationSequence                                           uint64
	Mode                                                             BridgeMessageMode
	PayloadDigest                                                    [32]byte
}

type DurableSourceMutationReceipt struct {
	TaskID      string                    `json:"task_id"`
	Fingerprint SourceMutationFingerprint `json:"fingerprint"`
	Result      BridgeIntentResult        `json:"result"`
}

type DurableActorTaskOutboxItem struct {
	TaskID                                           string            `json:"task_id"`
	Target                                           CommunicationPeer `json:"target"`
	TargetRef                                        DurableActorRef   `json:"target_ref"`
	Attempts                                         int               `json:"attempts"`
	NextAttempt                                      time.Time         `json:"next_attempt"`
	RequestID, DedupeID, ChainID, RequiredCapability string
	SourceMutationSequence                           uint64            `json:"source_mutation_sequence"`
	Deadline                                         time.Time         `json:"deadline"`
	HopLimit                                         uint32            `json:"hop_limit"`
	Mode                                             BridgeMessageMode `json:"mode"`
	Payload                                          []byte            `json:"payload"`
	PayloadDigest                                    [32]byte          `json:"payload_digest"`
	Credit                                           TaskCredit        `json:"credit"`
	State                                            string            `json:"state"`
}

type DurableTaskCreditReservation struct {
	Credit    TaskCredit      `json:"credit"`
	Source    string          `json:"source"`
	SourceRef DurableActorRef `json:"source_ref"`
}

type DurableActorRef struct {
	AgentID string `json:"agent_id"`
	Host    string `json:"host"`
	Port    int    `json:"port"`
	Name    string `json:"name"`
	Address string `json:"address"`
}

type DurablePendingCompletion struct {
	CompletionKey string             `json:"completion_key"`
	Source        DurableActorRef    `json:"source"`
	Completed     ActorTaskCompleted `json:"completed"`
	Attempts      int                `json:"attempts"`
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
	ActorMessageHighWater                                                           uint64
	SourceOutbox                                                                    []DurableActorTaskOutboxItem
	SourceTaskHistory                                                               []ActorTaskCompleted
	SourceMutationReceipts                                                          []DurableSourceMutationReceipt
	ReceivedTaskCompletions                                                         []ActorTaskCompleted
	TaskCreditEpoch                                                                 uint64
	TaskCreditReservations                                                          []DurableTaskCreditReservation
	AckCursor                                                                       uint64
	AckGapBuffer                                                                    []DurableBridgeAckRecord
	CommittedAcks                                                                   []DurableBridgeAckRecord
	TaskSources                                                                     map[uint64]DurableActorRef
	CompletionTellPending                                                           []DurablePendingCompletion
}

type DurableBridgeAckRecord struct {
	Sequence      uint64             `json:"sequence"`
	DedupeID      string             `json:"dedupe_id"`
	Kind          BridgeDeliveryKind `json:"kind"`
	SourceScope   string             `json:"source_scope"`
	CompletionKey string             `json:"completion_key"`
	RuntimeID     string             `json:"runtime_id"`
	Incarnation   uint64             `json:"incarnation"`
	PiSessionID   string             `json:"pi_session_id"`
	Delivered     bool               `json:"delivered"`
	Reason        string             `json:"reason"`
	Result        []byte             `json:"result,omitempty"`
}

type DurableAskCorrelation struct {
	SchemaVersion          int                  `json:"schema_version"`
	RecordKind             string               `json:"record_kind"`
	Key                    string               `json:"key"`
	RequestID              string               `json:"request_id"`
	DedupeID               string               `json:"dedupe_id"`
	ChainID                string               `json:"chain_id"`
	SourceMutationSequence uint64               `json:"source_mutation_sequence"`
	DeliverySequence       uint64               `json:"delivery_sequence"`
	Source                 CommunicationPeer    `json:"source"`
	Target                 CommunicationPeer    `json:"target"`
	TargetHomeNode         string               `json:"target_home_node"`
	OriginHomeNode         string               `json:"origin_home_node"`
	RequestingClient       string               `json:"requesting_client"`
	ReplyRoute             string               `json:"reply_route"`
	Deadline               time.Time            `json:"deadline"`
	PayloadDigest          [32]byte             `json:"payload_digest"`
	State                  string               `json:"state"`
	TerminalDigest         [32]byte             `json:"terminal_digest"`
	TerminalResult         BridgeIntentResult   `json:"terminal_result"`
	CreatedAt              time.Time            `json:"created_at"`
	UpdatedAt              time.Time            `json:"updated_at"`
	ReplayExpiresAt        time.Time            `json:"replay_expires_at"`
	TombstoneExpiresAt     time.Time            `json:"tombstone_expires_at"`
	FrontendPushLedger     map[string]time.Time `json:"frontend_push_ledger,omitempty"`
}

type DurableHostedPiBridgeState struct {
	SchemaVersion              int                               `json:"schema_version"`
	RecordKind                 string                            `json:"record_kind"`
	MigrationFromAgentRevision uint64                            `json:"migration_from_agent_revision"`
	MigrationID                string                            `json:"migration_id,omitempty"`
	MigrationInProgress        bool                              `json:"migration_in_progress,omitempty"`
	MigrationCommitted         bool                              `json:"migration_committed,omitempty"`
	AgentID                    string                            `json:"agent_id"`
	RuntimeID                  string                            `json:"runtime_id"`
	Incarnation                uint64                            `json:"incarnation"`
	SessionID                  string                            `json:"session_id"`
	GenerationID               string                            `json:"generation_id"`
	Principal                  string                            `json:"principal"`
	Handle                     string                            `json:"handle"`
	PiSessionID                string                            `json:"pi_session_id"`
	Fence                      uint64                            `json:"fence"`
	NextDeliverySequence       uint64                            `json:"next_delivery_sequence"`
	AckCursor                  uint64                            `json:"ack_cursor"`
	AckGapBuffer               map[uint64]DurableBridgeAckRecord `json:"ack_gap_buffer"`
	ReplayWindow               []BridgeDelivery                  `json:"replay_window"`
	DeliverySources            map[uint64]string                 `json:"delivery_sources"`
	MutationScopes             []DurableMutationScope            `json:"mutation_scopes"`
	ReadinessLeaseGeneration   uint64                            `json:"readiness_lease_generation"`
	Ready                      bool                              `json:"ready"`
	AskCorrelations            []DurableAskCorrelation           `json:"ask_correlations"`
	ReplyTombstones            map[string]time.Time              `json:"reply_tombstones"`
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
