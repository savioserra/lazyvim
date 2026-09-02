package application

import (
	"crypto/sha256"
	"fmt"

	"context"
	"errors"
	"time"

	"github.com/tochemey/goakt/v4/actor"
)

type Health struct{}
type SetHealth struct {
	Ready  bool
	Status string
}
type HealthState struct {
	Live   bool
	Ready  bool
	Status string
}

type OpenSession struct {
	SessionID    string
	GenerationID string
	Caller       string
	Credential   []byte
	Capabilities []string
	ExpiresAt    time.Time
	Persistent   bool
}
type CloseSession struct {
	SessionID    string
	GenerationID string
}
type CoordinationResult struct {
	Allowed   bool
	Completed bool
	Reason    string
}
type CoordinateOpen struct {
	Session OpenSession
	Result  chan<- CoordinationResult
}
type CoordinateClose struct {
	SessionID    string
	GenerationID string
	Result       chan<- CoordinationResult
}

type RegistryKind uint8

const (
	SessionRegistry RegistryKind = iota + 1
	AgentRegistry
)

type StageSession struct {
	Session     OpenSession
	Registry    RegistryKind
	Acknowledge *actor.PID
}
type SessionStageAck struct {
	SessionID    string
	GenerationID string
	Registry     RegistryKind
	Accepted     bool
}
type PrepareSessionClose struct {
	SessionID    string
	GenerationID string
	Registry     RegistryKind
	Acknowledge  *actor.PID
}
type SessionPrepareAck struct {
	SessionID    string
	GenerationID string
	Registry     RegistryKind
	AgentNames   []string
}
type CommitSessionClose struct {
	SessionID    string
	GenerationID string
	Registry     RegistryKind
	Acknowledge  *actor.PID
}
type SessionCommitAck struct {
	SessionID    string
	GenerationID string
	Registry     RegistryKind
}
type RetryCoordination struct {
	SessionID    string
	GenerationID string
}
type DropSession struct {
	SessionID    string
	GenerationID string
	AgentName    string
	Acknowledge  *actor.PID
	Result       chan<- OperationResult
}
type SessionDropped struct {
	SessionID    string
	GenerationID string
	AgentName    string
}
type SessionAuthorization struct {
	SessionID    string
	GenerationID string
	Caller       string
	Credential   []byte
	Capability   string
}
type AuthorizationResult struct {
	Allowed      bool
	GenerationID string
}

type AuthorityBindingKind uint8

const (
	AuthorityBindingUnspecified AuthorityBindingKind = iota
	AuthorityBindingPhaseOneObservedUpstream
	AuthorityBindingHostedOwned
)

type AuthorityBinding struct {
	Kind                  AuthorityBindingKind
	ObservedUpstreamRunID string
	HostedRuntimeID       string
}

var (
	ErrHostedOwnershipIndeterminate = errors.New("hosted runtime ownership is indeterminate")
	ErrHostedRuntimeUnexpectedExit  = errors.New("hosted runtime disappeared unexpectedly")
)

type HostedPiRuntimeState uint8
type HostedPiRuntimeLifetime uint8
type HostedPiTmuxOwnership uint8
type HostedPiControlBoundary uint8
type HostedPiVisualizationBoundary uint8

const (
	HostedPiRuntimeUnspecified HostedPiRuntimeState = iota
	HostedPiRuntimeInactive
	HostedPiRuntimeStarting
	HostedPiRuntimeReady
	HostedPiRuntimeDegraded
	HostedPiRuntimeStopping
	HostedPiRuntimeStopped
)
const (
	HostedPiLifetimeUnspecified HostedPiRuntimeLifetime = iota
	HostedPiLifetimeGlobalAgent
)
const (
	HostedPiTmuxOwnershipUnspecified HostedPiTmuxOwnership = iota
	HostedPiTmuxOwnershipExactSession
)
const (
	HostedPiControlUnspecified HostedPiControlBoundary = iota
	HostedPiControlDocumentedBridgeOnly
)
const (
	HostedPiVisualizationUnspecified HostedPiVisualizationBoundary = iota
	HostedPiVisualizationTmuxAttach
)

// HostedPiRuntimeBinding is the hosted-owned runtime's exact lifecycle and
// process/tmux ownership projection.
type HostedPiRuntimeBinding struct {
	State                  HostedPiRuntimeState
	Lifetime               HostedPiRuntimeLifetime
	TmuxOwnership          HostedPiTmuxOwnership
	ControlBoundary        HostedPiControlBoundary
	VisualizationBoundary  HostedPiVisualizationBoundary
	RuntimeID              string
	Incarnation            uint64
	TmuxSession            string
	TmuxWindow             string
	TmuxPane               string
	TmuxSessionID          string
	TmuxWindowID           string
	TmuxServerPID          int64
	TmuxServerStartToken   string
	PanePID                int64
	ProcessStartToken      string
	TTY                    string
	PiSessionDirectory     string
	PiSessionName          string
	BridgeReady            bool
	OwnershipIndeterminate bool
	CleanupPending         bool
	AggregateID            string
	DisplayName            string
	Role                   string
}

type HostedPiLaunchSpec struct {
	AgentID, RuntimeID, TmuxSession, TmuxWindow, PiSessionDirectory, PiSessionName string
	Incarnation                                                                    uint64
}

type HostedPiOwnedProcess interface {
	Binding() HostedPiRuntimeBinding
	Wait() error
	Stop(context.Context) error
}

type HostedPiRuntime interface {
	Start(context.Context, HostedPiLaunchSpec) (HostedPiOwnedProcess, error)
}

type StartHostedPiRuntime struct{ Timeout time.Duration }
type RetryHostedPiRuntime struct{ Token uint64 }
type StopHostedPiRuntime struct {
	Reason   string
	Timeout  time.Duration
	Accepted chan<- OperationResult
}
type HostedPiRuntimeStarted struct {
	Process HostedPiOwnedProcess
	Binding HostedPiRuntimeBinding
	Err     error
}
type HostedPiRuntimeExited struct{ Err error }
type HostedPiRuntimeStoppedResult struct{ Err error }
type HostedPiRuntimeStatus struct{}
type HostedPiRuntimeFailureStatus struct{}
type HostedPiRuntimeFailure struct{ Reason string }
type BindHostedPiRuntimeActor struct{ PID *actor.PID }
type RebindHostedPiRuntimeOwner struct{ PID *actor.PID }
type HostedPiRuntimeStateChanged struct {
	AgentID string
	Binding HostedPiRuntimeBinding
	Reason  string
}
type HostedPiBridgeReadiness struct{ Ready bool }
type HostedPiBridgeLeaseExpired struct{ Token uint64 }

func InactiveHostedPiRuntimeBinding() HostedPiRuntimeBinding {
	return HostedPiRuntimeBinding{
		State: HostedPiRuntimeInactive, Lifetime: HostedPiLifetimeGlobalAgent,
		TmuxOwnership: HostedPiTmuxOwnershipExactSession, ControlBoundary: HostedPiControlDocumentedBridgeOnly,
		VisualizationBoundary: HostedPiVisualizationTmuxAttach,
	}
}

type RegisterAgent struct {
	AgentID               string
	Role                  string
	DisplayName           string
	AuthorityBinding      AuthorityBinding
	HostedPiRuntime       HostedPiRuntimeBinding
	AllowedCapability     []string
	PhaseTwoOwned         bool
	Retention             string
	Recovery              string
	Runtime               HostedPiRuntime
	LaunchSpec            HostedPiLaunchSpec
	RuntimeStartTimeout   time.Duration
	AdoptedProcess        HostedPiOwnedProcess
	PersistencePID        *actor.PID
	PersistenceSupervisor *actor.PID
	DurableRecord         *DurableHostedRecord
}
type RegisterAgentResult struct {
	Created, CleanupPending bool
	RuntimePID, AgentPID    *actor.PID
	CleanupID               string
	Reason                  string
}
type CoordinateAgentRegistration struct {
	OperationID  string
	Registration RegisterAgent
	Result       chan<- RegisterAgentResult
}
type CompleteAgentRegistration struct{ OperationID string }
type ConfirmAgentRegistration struct{ OperationID string }
type AcknowledgeAgentRegistrationTracking struct{ OperationID string }
type CompensateAgentRegistration struct {
	OperationID string
	AgentID     string
	Result      chan<- UnregisterAgentResult
}
type FinishAgentRegistrationCompensation struct {
	OperationID string
	AgentID     string
	Results     []chan<- UnregisterAgentResult
	Err         error
	RuntimePID  *actor.PID
	Binding     HostedPiRuntimeBinding
}
type UnregisterAgent struct {
	AgentID string
	Result  chan<- UnregisterAgentResult
}
type UnregisterAgentResult struct {
	Completed  bool
	Reason     string
	RuntimePID *actor.PID
	AgentPID   *actor.PID
	Binding    HostedPiRuntimeBinding
}

// ResolveAgentControl is daemon-internal lifecycle resolution. It carries no
// client authority and always resolves the current incarnation by actor name.
type ResolveAgentControl struct{ AgentID string }
type AgentControlPID struct {
	PID       *actor.PID
	Found     bool
	Reference AgentReference
}
type RetryAgentReconciliation struct {
	AgentID string
	Attempt uint8
}

const HostedPlacementAuthorityNamePrefix = "hosted-placement-authority-v4-"

func HostedPlacementAuthorityName(nodeIdentity string) string {
	digest := sha256.Sum256([]byte(nodeIdentity))
	return HostedPlacementAuthorityNamePrefix + fmt.Sprintf("%x", digest[:8])
}

type ConfigurePublicAgentEvents struct {
	NodeIdentity       string
	PlacementAuthority string
	Epoch              uint64
}

type PublishPublicAgentSnapshot struct{}

type PublishPublicAgentSnapshotTick struct{}

type PublicAgentSnapshotRequest struct {
	NodeIdentity string
}

const ClientAgentRosterTopic = "subagents.client.agent_roster"
const ActorMessageReplyTopic = "subagents.actor.message_replies"

const (
	HostedPiBridgeActorStableNamePrefix = "agents/"
	HostedPiBridgeActorNonAuthoritative = "non-authoritative-additive-migration-boundary"
)

func HostedPiBridgeActorStableName(agentID, runtimeID string, incarnation uint64) string {
	return fmt.Sprintf("agents/%s/bridge/%s/%d", agentID, runtimeID, incarnation)
}

func HostedPiBridgeActorSpawnName(agentID, runtimeID string, incarnation uint64) string {
	digest := sha256.Sum256([]byte(HostedPiBridgeActorStableName(agentID, runtimeID, incarnation)))
	return "hosted-pi-bridge-" + fmt.Sprintf("%x", digest[:8])
}

const (
	ClientAgentRosterStatus        = "status"
	ClientAgentRosterSnapshotReset = "snapshot-reset"
	ClientAgentRosterUpsert        = "upsert"
	ClientAgentRosterRemove        = "remove"
)

type ClientAgentRosterEvent struct {
	Operation string
	Epoch     uint64
	Sequence  uint64
	AgentID   string
	Reference AgentReference
	Status    string
}

type ClientAgentRosterSnapshot struct {
	SessionID     string
	GenerationID  string
	Caller        string
	Credential    []byte
	LastEpoch     uint64
	AfterSequence uint64
}

type ClientAgentRosterSnapshotResult struct {
	Events []ClientAgentRosterEvent
	Reason string
}

type PublicAgentDirectoryEvent struct {
	Operation    string
	NodeIdentity string
	AgentID      string
	ActorName    string
	Epoch        uint64
	Sequence     uint64
	Reference    AgentReference
}

type ListAgents struct {
	SessionID    string
	GenerationID string
	Caller       string
	Credential   []byte
}
type ResolveAgent struct {
	SessionID    string
	GenerationID string
	Caller       string
	Credential   []byte
	AgentID      string
}
type AgentReference struct {
	AgentID           string
	LifecycleRevision uint64
	Role              string
	DisplayName       string
	RetentionPolicy   string
	RecoveryPolicy    string
	AuthorityBinding  AuthorityBinding
	HostedPiRuntime   HostedPiRuntimeBinding
}
type AgentList struct{ Agents []AgentReference }
type ResolveAgentResult struct {
	Found      bool
	Ambiguous  bool
	Agent      AgentReference
	Candidates []AgentReference
}
type AuthorizeAgentAccess struct {
	SessionID    string
	GenerationID string
	Caller       string
	Credential   []byte
	AgentID      string
	Capabilities []string
}
type AgentRoute struct {
	Allowed      bool
	PID          *actor.PID
	GenerationID string
	Principal    string
	Reason       string
}

type PublicNode struct {
	Identity   string
	Host       string
	Port       int
	ClientPort int
	Stale      bool
}
type PublicAgentPlacement struct{ NodeIdentity string }
type CreatePublicAgent struct {
	SessionID, GenerationID, Caller string
	Credential                      []byte
	AgentID, Role, DisplayName      string
	ActorName                       string
	Reference                       AgentReference
	Placement                       PublicAgentPlacement
	Private                         bool
	Internal                        bool
}
type PublicAgentRecord struct {
	AgentID, ActorName, HomeNode, Host, Role, DisplayName string
	Port                                                  int
	Revision                                              uint64
	Private                                               bool
	Reference                                             AgentReference
}
type PublicAgentCreateResult struct {
	Created bool
	Record  PublicAgentRecord
	PID     *actor.PID
	Reason  string
}
type LookupPublicAgent struct {
	SessionID, GenerationID, Caller string
	Credential                      []byte
	AgentID                         string
}
type PublicAgentLookupResult struct {
	Found  bool
	Record PublicAgentRecord
	Reason string
}
type RoutePublicAgent struct {
	SessionID, GenerationID, Caller string
	Credential                      []byte
	AgentID                         string
	Capabilities                    []string
}
type PublicAgentRouteResult struct {
	Allowed bool
	PID     *actor.PID
	Record  PublicAgentRecord
	Reason  string
}
type PublicAgentTell struct {
	DedupeID string
	Payload  []byte
}
type PublicAgentAsk struct {
	DedupeID string
	Payload  []byte
}
type RemoteHostedPlacement struct {
	ProtocolVersion                               uint32
	OperationID, DedupeID, SourceNode, TargetNode string
	DeadlineUnixMillis                            int64
	AgentID, ProjectDirectory, DisplayName, Role  string
	TrustProject                                  bool
	CertificateDER                                [][]byte
	Signature                                     []byte
}
type RemoteHostedPlacementResult struct {
	Accepted           bool
	AgentID, ActorName string
	Reference          AgentReference
	Runtime            HostedPiRuntimeBinding
	Reason             string
}
type ResolveAgentActor struct{ AgentID string }
type AgentActorRef struct {
	AgentID, ActorName string
	Found              bool
	Reason             string
}

type RemoteAttachAgent struct {
	SessionID, GenerationID, Principal, AgentID string
	RequestedCapabilities                       []string
	IssuedHandle                                string
}
type ListPublicHostedAgents struct {
	Limit uint32
}
type ListPublicHostedAgentsResult struct {
	Agents []PublicHostedAgent
	Reason string
}
type PublicHostedAgent struct {
	AgentID, ActorName string
	Reference          AgentReference
}

type RemoteBridgeIntent struct {
	SessionID, GenerationID, Principal, Handle, SourceAgentID, TargetAgentID, RequestID, RequiredCapability, DedupeID, ChainID string
	Fence, SourceMutationSequence                                                                                              uint64
	Deadline                                                                                                                   time.Time
	HopLimit                                                                                                                   uint32
	Mode                                                                                                                       BridgeMessageMode
	Payload                                                                                                                    []byte
	ReplyTopic                                                                                                                 string
}

type ActorMessageReply struct {
	SessionID, GenerationID, Principal, SourceAgentID, TargetAgentID, RequestID, DedupeID, ChainID string
	SourceMutationSequence                                                                         uint64
	Mode                                                                                           BridgeMessageMode
	Result                                                                                         BridgeIntentResult
}

type SendActorTask struct {
	TargetPID                                        *actor.PID
	TargetPeer                                       CommunicationPeer
	RequestID, DedupeID, ChainID, RequiredCapability string
	SourceMutationSequence                           uint64
	Deadline                                         time.Time
	HopLimit                                         uint32
	Mode                                             BridgeMessageMode
	Payload                                          []byte
	Receipt                                          chan<- BridgeIntentResult
}

type TaskCredit struct {
	TaskID, CreditID string
	TargetEpoch      uint64
	ExpiresAt        time.Time
	PayloadDigest    [32]byte
}

type RequestTaskCredit struct {
	TaskID, RequestID, DedupeID, ChainID string
	SourcePeer                           CommunicationPeer
	Deadline                             time.Time
	PayloadDigest                        [32]byte
}

type TaskCreditGranted struct{ Credit TaskCredit }

type TaskBackpressured struct {
	TaskID, Reason string
	TargetEpoch    uint64
	RetryAfter     time.Duration
}

type ActorTask struct {
	Credit                                           TaskCredit
	SourcePeer, TargetPeer                           CommunicationPeer
	RequestID, DedupeID, ChainID, RequiredCapability string
	SourceMutationSequence                           uint64
	Deadline                                         time.Time
	HopLimit                                         uint32
	Mode                                             BridgeMessageMode
	Payload                                          []byte
}

const TargetTaskCommittedTopic = "subagents.target-task-committed"

type ActorTaskAccepted struct {
	TaskID, CreditID string
	TargetAgentID    string
	Accepted         bool
	Reason           string
}

type TargetTaskCommitted struct {
	TaskID, TargetAgentID string
}

type ActorTaskCompleted struct {
	CompletionKey                        string
	OriginalRequestID, DedupeID, ChainID string
	SourceMutationSequence               uint64
	Terminal                             BridgeIntentResult
	Source, Target                       CommunicationPeer
	Kind                                 BridgeDeliveryKind
}

type DrainReceivedTaskCompletions struct {
	Result chan<- []ActorTaskCompleted
}

type CommitBridgeDelivery struct {
	SourcePeer, TargetPeer                                       CommunicationPeer
	SourceHomeNode, TargetHomeNode, RequestID, DedupeID, ChainID string
	SourceScope, ReplyRoute, RequestingClientGeneration          string
	SourceMutationSequence                                       uint64
	Deadline                                                     time.Time
	HopLimit                                                     uint32
	Kind                                                         BridgeDeliveryKind
	Policy                                                       BridgeDeliveryPolicy
	Payload                                                      []byte
	Admission                                                    chan<- BridgeIntentResult
}

type BridgeDeliveryAckEvidence struct {
	SessionID, GenerationID, Principal, Handle, RuntimeID, PiSessionID, DedupeID, SourceScope, Reason string
	Fence, Incarnation, Sequence                                                                      uint64
	Kind                                                                                              BridgeDeliveryKind
	Delivered                                                                                         bool
	Result                                                                                            []byte
	Completion                                                                                        chan<- BridgeDeliveryAckResult
}

type CompleteAskCorrelation struct {
	CompletionKey string
	Reason        string
}

type RouteActorMessageReply struct {
	CompletionKey                                              string
	OriginalRequestID, DedupeID, ChainID                       string
	SourceMutationSequence                                     uint64
	Terminal                                                   BridgeIntentResult
	Source, Target                                             CommunicationPeer
	Kind                                                       BridgeDeliveryKind
	OriginHomeNode, TargetHomeNode, RequestingClientGeneration string
}

type MarkFrontendCompletionDelivered struct {
	CompletionKey string
	GenerationID  string
	Result        chan<- OperationResult
}

type StopHostedBridge struct {
	AgentID, RuntimeID string
	Incarnation        uint64
	Reason             string
	Result             chan<- OperationResult
}

type RuntimeIncarnationRetired struct {
	AgentID, RuntimeID string
	Incarnation        uint64
	Reason             string
}

type HostedPiBridgeStatus struct{}

type HostedPiBridgeStateSnapshot struct {
	StableName           string
	MigrationBoundary    string
	State                DurableHostedPiBridgeState
	PendingReplay        []BridgeDelivery
	TerminalReplyKeys    []string
	NonAuthoritativeOnly bool
}

type AgentProjectionEvent struct {
	AgentID         string
	Revision        uint64
	CommandSequence uint64
	Operation       string
	OriginSessionID string
}
type AttachAgent struct {
	SessionID             string
	GenerationID          string
	Principal             string
	AgentID               string
	RequestedCapabilities []string
	IssuedHandle          string
	Result                chan<- AttachResult
}
type ReattachAgent struct {
	SessionID      string
	GenerationID   string
	Principal      string
	AgentID        string
	PreviousHandle string
	PreviousFence  uint64
	IssuedHandle   string
	Result         chan<- AttachResult
}
type DetachAgent struct {
	SessionID    string
	GenerationID string
	Principal    string
	AgentID      string
	Handle       string
	Fence        uint64
	Result       chan<- OperationResult
}
type SubscribeAgent struct {
	SessionID     string
	GenerationID  string
	Principal     string
	AgentID       string
	Handle        string
	Fence         uint64
	AfterRevision uint64
	Result        chan<- OperationResult
}
type UnsubscribeAgent struct {
	SessionID, GenerationID, Principal, AgentID, Handle string
	Fence                                               uint64
	Result                                              chan<- OperationResult
}

type BridgeConnect struct {
	SessionID, GenerationID, Principal, AgentID, Handle, RuntimeID, PiSessionID string
	Fence, Incarnation                                                          uint64
	Result                                                                      chan<- BridgeResult
}
type BridgeReplace struct {
	SessionID, GenerationID, Principal, AgentID, Handle, RuntimeID, PreviousPiSessionID, NewPiSessionID, NewHandle string
	Fence, Incarnation                                                                                             uint64
	Result                                                                                                         chan<- BridgeResult
}
type BridgeLifecycleEvent uint8

const (
	BridgeLifecycleUnspecified BridgeLifecycleEvent = iota
	BridgeLifecycleSessionStart
	BridgeLifecycleReady
	BridgeLifecycleSessionShutdown
	BridgeLifecycleAgentStart
	BridgeLifecycleAgentSettled
)

type BridgeLifecycle struct {
	SessionID, GenerationID, Principal, AgentID, Handle, RuntimeID string
	Fence, Incarnation                                             uint64
	Event                                                          BridgeLifecycleEvent
	Result                                                         chan<- BridgeResult
}
type BridgeHeartbeat struct {
	SessionID, GenerationID, Principal, AgentID, Handle, RuntimeID string
	Fence, Incarnation                                             uint64
	Result                                                         chan<- BridgeResult
}
type BridgeResult struct {
	Accepted              bool
	NeedsAttach           bool
	Handle                string
	Fence                 uint64
	Reason                string
	ActorMessageHighWater uint64
}
type BridgeMessageMode uint8

const (
	BridgeMessageUnspecified BridgeMessageMode = iota
	BridgeMessageTell
	BridgeMessageAsk
	BridgeMessagePrompt
)

type BridgeIntent struct {
	SessionID, GenerationID, Principal, Handle, SourceAgentID, TargetAgentID, RequestID, RequiredCapability, DedupeID, ChainID string
	Fence, SourceMutationSequence                                                                                              uint64
	Deadline                                                                                                                   time.Time
	HopLimit                                                                                                                   uint32
	Mode                                                                                                                       BridgeMessageMode
	Payload                                                                                                                    []byte
	Completion                                                                                                                 chan<- BridgeIntentResult
	Receipt                                                                                                                    chan<- BridgeIntentResult
}
type BridgeIntentResult struct {
	Accepted, Completed, AwaitingAck bool
	Result                           []byte
	Reason                           string
}
type BridgeControlIntent uint8

const (
	BridgeControlUnspecified BridgeControlIntent = iota
	BridgeControlAbort
	BridgeControlShutdown
)

type BridgeControl struct {
	SessionID, GenerationID, Principal, Handle, SourceAgentID, TargetAgentID, RequestID, DedupeID, ChainID string
	Fence, SourceMutationSequence                                                                          uint64
	Deadline                                                                                               time.Time
	HopLimit                                                                                               uint32
	Intent                                                                                                 BridgeControlIntent
	Completion                                                                                             chan<- BridgeIntentResult
}

type BridgeDeliveryPolicy uint8

const (
	BridgeDeliveryPolicyUnspecified BridgeDeliveryPolicy = iota
	BridgeDeliveryIdleElseSteer
	BridgeDeliveryIdleElseFollowUp
)

type BridgeDeliveryKind uint8

const (
	BridgeDeliveryUnspecified BridgeDeliveryKind = iota
	BridgeDeliveryNotification
	BridgeDeliveryAbort
	BridgeDeliveryShutdown
	BridgeDeliveryPrompt
)

type CommunicationPeer struct {
	StableID    string
	DisplayName string
	Role        string
}

func BridgeDeliveryKindLabel(kind BridgeDeliveryKind) string {
	switch kind {
	case BridgeDeliveryNotification:
		return "notification"
	case BridgeDeliveryAbort:
		return "abort"
	case BridgeDeliveryShutdown:
		return "shutdown"
	case BridgeDeliveryPrompt:
		return "prompt"
	default:
		return ""
	}
}

type BridgeDelivery struct {
	Sequence                                                   uint64
	SourceAgentID, TargetAgentID, RequestID, DedupeID, ChainID string
	Source, Target                                             CommunicationPeer
	Deadline                                                   time.Time
	HopLimit                                                   uint32
	Payload                                                    []byte
	Policy                                                     BridgeDeliveryPolicy
	Kind                                                       BridgeDeliveryKind
	SourceScope, CompletionKey                                 string
	DeliveryBackend                                            string
}

// AckIdentityComplete reports whether the delivery carries the opaque
// server-issued source scope token and completion key that every bridge
// acknowledgement must echo. A delivery without both can never be
// acknowledged and must never be pushed or polled to a hosted bridge.
func (d BridgeDelivery) AckIdentityComplete() bool {
	return d.SourceScope != "" && d.CompletionKey != ""
}

type BridgeEvent struct {
	Sequence, Revision uint64
	AgentID, Operation string
}
type PollBridge struct {
	SessionID, GenerationID, Principal, Handle string
	Fence, AfterSequence                       uint64
	MaxItems                                   uint32
}
type BridgeDeliveryAck struct {
	SessionID, GenerationID, Principal, Handle, DedupeID, Reason string
	Fence, Sequence                                              uint64
	Delivered                                                    bool
	Result                                                       []byte
	RuntimeID, PiSessionID, Kind, SourceScope, CompletionKey     string
	Incarnation                                                  uint64
	Completion                                                   chan<- BridgeDeliveryAckResult
}
type BridgeDeliveryAckResult struct {
	Accepted bool
	Reason   string
	Cursor   uint64
}

type BridgeSessionOpened struct{ Session any }
type BridgeSessionClosed struct{ Session any }
type BridgeSessionAgentUpdate struct {
	AgentID string
	Reason  string
}
type BridgeSessionPushCompleted struct {
	Advanced bool
	Reason   string
}

type QuarantineDurableHostedState struct {
	AgentID string
	Reason  string
	Err     error
}
type DurableQuarantineStatus struct{}
type DurableQuarantineState struct {
	FailClosed bool
	Items      map[string]string
}

type WorkflowStage uint8

const (
	WorkflowStageUnspecified WorkflowStage = iota
	WorkflowStageWorker
	WorkflowStageReviewer
	WorkflowStageQA
	WorkflowStageCorrection
	WorkflowStageCompleted
	WorkflowStageFailed
)

type StartWorkflow struct {
	WorkflowID string
	Task       string
	Result     chan<- OperationResult
}
type WorkflowStageResult struct {
	WorkflowID string
	Stage      WorkflowStage
	Evidence   string
	Accepted   bool
	Reason     string
}
type WorkflowStatus struct{ WorkflowID string }
type WorkflowState struct {
	WorkflowID string
	Stage      WorkflowStage
	Evidence   []string
	Terminal   bool
	Reason     string
}
type BridgeIntentTimeout struct {
	ScopeKey string
	DedupeID string
}

type BridgePollResult struct {
	Events         []BridgeEvent
	Deliveries     []BridgeDelivery
	LatestSequence uint64
	More           bool
	Reason         string
}
type AgentCommand struct {
	SessionID     string
	GenerationID  string
	Principal     string
	AgentID       string
	Handle        string
	Fence         uint64
	Capability    string
	Operation     string
	RequestID     string
	PayloadDigest [32]byte
}
type AttachResult struct {
	Completed bool
	Handle    string
	Fence     uint64
	Reason    string
}
type OperationResult struct {
	Completed bool
	Revision  uint64
	Reason    string
}
type CommandResult struct {
	Completed       bool
	CommandSequence uint64
	Revision        uint64
	Subscribers     []string
	Reason          string
}
type Subscribers struct{ AgentID string }
type SubscriberList struct{ SessionIDs []string }
