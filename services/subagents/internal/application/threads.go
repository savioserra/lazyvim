package application

import (
	"crypto/sha256"
	"encoding/base32"
	"encoding/binary"
	"encoding/hex"
	"strconv"
	"strings"
	"time"
)

const (
	DurableAgentThreadSchemaV1     = 1
	DurableThreadSchedulerSchemaV1 = 1
	MaxDurableAgentThreads         = 256
	MaxDurableThreadEvents         = 128
)

type AgentThreadState string

const (
	AgentThreadQueued               AgentThreadState = "queued"
	AgentThreadActive               AgentThreadState = "active"
	AgentThreadAwaitingAgentEnd     AgentThreadState = "awaiting_agent_end"
	AgentThreadAwaitingAgentSettled AgentThreadState = "awaiting_agent_settled"
	AgentThreadSettled              AgentThreadState = "settled"
	AgentThreadIntrospecting        AgentThreadState = "introspecting"
	AgentThreadResumable            AgentThreadState = "resumable"
	AgentThreadWaiting              AgentThreadState = "waiting"
	AgentThreadBlocked              AgentThreadState = "blocked"
	AgentThreadCompleted            AgentThreadState = "completed"
	AgentThreadFailed               AgentThreadState = "failed"
	AgentThreadExhausted            AgentThreadState = "exhausted"
)

type DurableThreadEvent struct {
	Sequence         uint64    `json:"sequence"`
	Kind             string    `json:"kind"`
	At               time.Time `json:"at"`
	DeliverySequence uint64    `json:"delivery_sequence,omitempty"`
	BridgeRunCounter uint64    `json:"bridge_run_counter,omitempty"`
	Digest           [32]byte  `json:"digest,omitempty"`
	Reason           string    `json:"reason,omitempty"`
}

type DurableAgentThread struct {
	SchemaVersion          int                  `json:"schema_version"`
	ThreadID               string               `json:"thread_id"`
	Source                 CommunicationPeer    `json:"source"`
	Target                 CommunicationPeer    `json:"target"`
	SourceRef              DurableActorRef      `json:"source_ref"`
	RequestID              string               `json:"request_id"`
	DedupeID               string               `json:"dedupe_id"`
	ChainID                string               `json:"chain_id"`
	SourceMutationSequence uint64               `json:"source_mutation_sequence"`
	PayloadDigest          [32]byte             `json:"payload_digest"`
	Mode                   BridgeMessageMode    `json:"mode"`
	RequiredCapability     string               `json:"required_capability,omitempty"`
	SourceScope            string               `json:"source_scope"`
	DeliverySourceKey      string               `json:"delivery_source_key"`
	DeliveryBackend        string               `json:"delivery_backend"`
	PendingPrompt          []byte               `json:"pending_prompt,omitempty"`
	Deadline               time.Time            `json:"deadline"`
	HopLimit               uint32               `json:"hop_limit"`
	State                  AgentThreadState     `json:"state"`
	Turn                   uint64               `json:"turn"`
	ActiveDeliverySequence uint64               `json:"active_delivery_sequence,omitempty"`
	CompletionKey          string               `json:"completion_key"`
	RetryCount             uint32               `json:"retry_count,omitempty"`
	ResumeAttempts         uint32               `json:"resume_attempts,omitempty"`
	NextAttempt            time.Time            `json:"next_attempt,omitempty"`
	Checkpoint             string               `json:"checkpoint,omitempty"`
	CheckpointDigest       [32]byte             `json:"checkpoint_digest,omitempty"`
	WorkerResult           []byte               `json:"worker_result,omitempty"`
	WorkerResultDigest     [32]byte             `json:"worker_result_digest,omitempty"`
	FailureClass           string               `json:"failure_class,omitempty"`
	EventCursor            uint64               `json:"event_cursor"`
	Events                 []DurableThreadEvent `json:"events,omitempty"`
}

type DurableThreadTombstone struct {
	ThreadID      string           `json:"thread_id"`
	State         AgentThreadState `json:"state"`
	CompletionKey string           `json:"completion_key"`
	ResultDigest  [32]byte         `json:"result_digest,omitempty"`
	ExpiresAt     time.Time        `json:"expires_at,omitempty"`
}

type DurableThreadScheduler struct {
	SchemaVersion  int                      `json:"schema_version"`
	AgentID        string                   `json:"agent_id"`
	Epoch          uint64                   `json:"epoch"`
	ActiveThreadID string                   `json:"active_thread_id,omitempty"`
	ActiveLease    uint64                   `json:"active_lease"`
	Queue          []string                 `json:"queue,omitempty"`
	Resumable      []string                 `json:"resumable,omitempty"`
	Waiting        []string                 `json:"waiting,omitempty"`
	Blocked        []string                 `json:"blocked,omitempty"`
	Tombstones     []DurableThreadTombstone `json:"tombstones,omitempty"`
	RoundRobin     uint64                   `json:"round_robin"`
	NewWorkDeficit uint32                   `json:"new_work_deficit"`
}

type AgentThreadFingerprint struct {
	TargetAgentID, SourceAgentID, RequestID, DedupeID, ChainID, RequiredCapability string
	SourceMutationSequence                                                         uint64
	PayloadDigest                                                                  [32]byte
	Mode                                                                           BridgeMessageMode
	DeadlineUnixMillis                                                             int64
	HopLimit                                                                       uint32
}

func NewAgentThreadFingerprint(targetAgentID string, intent *BridgeIntent) AgentThreadFingerprint {
	if intent == nil {
		return AgentThreadFingerprint{}
	}
	return AgentThreadFingerprint{TargetAgentID: targetAgentID, SourceAgentID: intent.SourceAgentID, RequestID: intent.RequestID, DedupeID: intent.DedupeID, ChainID: intent.ChainID, RequiredCapability: intent.RequiredCapability, SourceMutationSequence: intent.SourceMutationSequence, PayloadDigest: sha256.Sum256(intent.Payload), Mode: intent.Mode, DeadlineUnixMillis: intent.Deadline.UnixMilli(), HopLimit: intent.HopLimit}
}

func (f AgentThreadFingerprint) ThreadID() string {
	parts := []string{"agent-thread-v1", f.TargetAgentID, f.SourceAgentID, f.RequestID, f.DedupeID, f.ChainID, strconv.FormatUint(f.SourceMutationSequence, 10), hex.EncodeToString(f.PayloadDigest[:])}
	digest := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(digest[:]))
}

func (t DurableAgentThread) Fingerprint() AgentThreadFingerprint {
	return AgentThreadFingerprint{TargetAgentID: t.Target.StableID, SourceAgentID: t.Source.StableID, RequestID: t.RequestID, DedupeID: t.DedupeID, ChainID: t.ChainID, RequiredCapability: t.RequiredCapability, SourceMutationSequence: t.SourceMutationSequence, PayloadDigest: t.PayloadDigest, Mode: t.Mode, DeadlineUnixMillis: t.Deadline.UnixMilli(), HopLimit: t.HopLimit}
}

func (f AgentThreadFingerprint) Digest() [32]byte {
	buffer := make([]byte, 0, 256)
	for _, value := range []string{f.TargetAgentID, f.SourceAgentID, f.RequestID, f.DedupeID, f.ChainID, f.RequiredCapability} {
		buffer = append(buffer, value...)
		buffer = append(buffer, 0)
	}
	var numeric [20]byte
	binary.BigEndian.PutUint64(numeric[0:8], f.SourceMutationSequence)
	binary.BigEndian.PutUint64(numeric[8:16], uint64(f.DeadlineUnixMillis))
	binary.BigEndian.PutUint32(numeric[16:20], f.HopLimit)
	buffer = append(buffer, numeric[:]...)
	buffer = append(buffer, byte(f.Mode))
	buffer = append(buffer, f.PayloadDigest[:]...)
	return sha256.Sum256(buffer)
}
