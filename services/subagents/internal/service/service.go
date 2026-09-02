package service

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/savioserra/lazyvim/services/subagents/internal/hostedpi"
	"github.com/savioserra/lazyvim/services/subagents/internal/protocol"
	"github.com/savioserra/lazyvim/services/subagents/internal/remoting"
	"github.com/savioserra/lazyvim/services/subagents/internal/securepath"
	workstationsocket "github.com/savioserra/lazyvim/services/subagents/internal/socket"
	durablestate "github.com/savioserra/lazyvim/services/subagents/internal/state"
	"github.com/tochemey/goakt/v4/actor"
	goaktlog "github.com/tochemey/goakt/v4/log"
	"github.com/tochemey/goakt/v4/passivation"
	"github.com/tochemey/goakt/v4/supervisor"
	"google.golang.org/protobuf/proto"
)

var clientSessionTTL = 30 * time.Minute
var terminalIdentityPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,48}$`)

const (
	requestTimeout                   = 2 * time.Second
	maxConnections                   = 32
	maxConnectionReplay              = 256
	maxSequenceAdvance        uint64 = 1024
	maxRequestResults                = 1024
	maxRequestIdentities             = 4096
	maxTemporaryAcceptRetries        = 3
	maxPromptBytes                   = 16 * 1024
	actorTaskDeliveryLifetime        = 6 * time.Hour
)

type HostedAdminConfig struct {
	Enabled                                                                                               bool
	TmuxBinary, PiBinary, BridgeExtension, ServerName, TmuxConfig, ActorEndpoint                          string
	StateDirectory, PiSessionDirectory, CredentialDirectory, AdminCredentialFile, DefaultProjectDirectory string
	IntrospectionModel                                                                                    string
	TrustProject                                                                                          bool
	RuntimeFactory                                                                                        func(hostedpi.Config) application.HostedPiRuntime
	IntrospectionRunner                                                                                   application.ThreadIntrospectionRunner
}
type hostedRegistration struct{ sessionID, credentialFile string }
type registrationPlaceholder struct {
	operationID, agentID string
	registration         application.RegisterAgent
	metadata             hostedRegistration
	outcome              chan application.RegisterAgentResult
	compensation         chan application.UnregisterAgentResult
	done                 chan struct{}
	lastErr              error
}
type registrationCleanup struct {
	operationID, agentID         string
	agentPID, runtimePID         *actor.PID
	metadata                     hostedRegistration
	binding                      application.HostedPiRuntimeBinding
	mu                           sync.Mutex
	runtimeStopped, agentStopped bool
	removeDurable                bool
	lastErr                      error
}
type Service struct {
	system             actor.ActorSystem
	guardian           *actor.PID
	sessionRegistry    *actor.PID
	agentRegistry      *actor.PID
	sessionCoordinator *actor.PID
	hostedSupervisor   *actor.PID
	workflowRegistry   *actor.PID
	taskCoordinator    *actor.PID
	publicDirectory    *actor.PID
	bridgeWatcher      *actor.PID
	listener           net.Listener
	actorPlane         *remoting.Runtime

	connections       sync.WaitGroup
	connectionSlots   chan struct{}
	connectionMu      sync.Mutex
	activeConnections map[net.Conn]struct{}
	stopping          atomic.Bool
	stopMu            sync.Mutex
	stopped           bool
	stopResult        error

	admissionMu  sync.Mutex
	admissionErr error

	requestMu      sync.Mutex
	requestResults map[string]requestRecord
	requestOrder   []string

	hostedMu                 sync.Mutex
	hostedRuntimes           map[string]*actor.PID
	hostedRegistrations      map[string]hostedRegistration
	hostedTerminal           map[string]application.HostedPiRuntimeBinding
	hostedStartupFailure     map[string]string
	hostedCleanup            map[string]hostedRegistration
	hostedProjects           map[string]string
	hostedStarting           map[string]int
	registrationPlaceholders map[string]*registrationPlaceholder
	registrationCleanups     map[string]*registrationCleanup
	closeHostedSession       func(context.Context, string) error
	removeHostedCredential   func(string) error
	hostedAdmin              HostedAdminConfig
	adminCredential          []byte
	adminCredentialFile      string
	socketPath               string
	hostedOperationMu        sync.Mutex
	hostedOperationDone      chan struct{}
	hostedOperationCount     int
	hostedOperationNext      uint64
	hostedOperationCancels   map[uint64]context.CancelFunc
	hostedAgentLocks         map[string]*sync.Mutex
	registrationTimeout      time.Duration
	durableStore             *durablestate.Store
	persistencePID           *actor.PID
	introspectionRunner      application.ThreadIntrospectionRunner
	persistenceSupervisor    *actor.PID
	hostedIndeterminate      map[string]application.HostedPiRuntimeBinding
	clientSessionMu          sync.Mutex
	clientSessions           map[string]*actor.PID
	publicSessionGenerations map[string]string

	pushMu       sync.Mutex
	pushSessions map[*bridgePushSession]*actor.PID

	rosterMu       sync.Mutex
	rosterSessions map[*clientRosterSession]*actor.PID

	actorReplyMu       sync.Mutex
	actorReplySessions map[string]*actorReplySession
	actorReplies       map[string][]actorReplyRecord
	actorReplyNext     map[string]uint64
}

type requestRecord struct {
	digest   [32]byte
	response *subagentsv1.Envelope // nil after result eviction; identity remains fail-closed
}

type sequenceRecord struct {
	digest   [32]byte
	response *subagentsv1.Envelope
}

type connectionReplay struct {
	highest uint64
	entries map[uint64]sequenceRecord
	order   []uint64
}

type clientRosterSession struct {
	mu                                 sync.Mutex
	sessionID, generationID, principal string
	credential                         []byte
	lastEpoch, afterSequence           uint64
	writer                             chan<- *subagentsv1.Envelope
	closed                             <-chan struct{}
}

type bridgePushSession struct {
	mu                                                  sync.Mutex
	sessionID, generationID, principal, agentID, handle string
	credential                                          []byte
	fence, afterSequence                                uint64
	writer                                              chan<- *subagentsv1.Envelope
	closed                                              <-chan struct{}
}

type actorReplySession struct {
	mu                                 sync.Mutex
	sessionID, generationID, principal string
	credential                         []byte
	selfHandle                         string
	selfFence, afterSequence           uint64
	writer                             chan<- *subagentsv1.Envelope
	closed                             <-chan struct{}
}

type actorReplyRecord struct {
	sequence  uint64
	delivered bool
	frame     *subagentsv1.Envelope
}

func Start(ctx context.Context, socketPath string) (*Service, error) {
	return StartConfigured(ctx, socketPath, HostedAdminConfig{})
}

func StartConfigured(ctx context.Context, socketPath string, hosted HostedAdminConfig, runtime ...*remoting.Runtime) (*Service, error) {
	if err := validateHostedAdminConfig(hosted); err != nil {
		return nil, err
	}
	if hosted.Enabled && hosted.IntrospectionRunner == nil && hosted.IntrospectionModel != "" {
		runner, err := hostedpi.NewIntrospectionRunner(hostedpi.IntrospectionConfig{PiBinary: hosted.PiBinary, Model: hosted.IntrospectionModel})
		if err != nil {
			return nil, err
		}
		hosted.IntrospectionRunner = runner
	}
	listener, err := workstationsocket.Listen(socketPath)
	if err != nil {
		return nil, err
	}
	options := []any{hosted, socketPath}
	if len(runtime) > 1 {
		_ = listener.Close()
		return nil, errors.New("only one remoting runtime may be configured")
	}
	if len(runtime) == 1 && runtime[0] != nil {
		options = append(options, runtime[0])
	}
	service, err := startWithListener(ctx, listener, options...)
	if err != nil {
		_ = listener.Close()
		return nil, err
	}
	return service, nil
}

type registryTestDelay time.Duration

func hostedActorEndpoint(config HostedAdminConfig) string {
	if config.ActorEndpoint != "" {
		return config.ActorEndpoint
	}
	return "ws://127.0.0.1:17213/actors"
}

func publicNodeMap(runtime *remoting.Runtime) map[string]application.PublicNode {
	result := make(map[string]application.PublicNode, len(runtime.PublicNodes))
	for identity, node := range runtime.PublicNodes {
		result[identity] = node
	}
	return result
}

func startWithListener(ctx context.Context, listener net.Listener, options ...any) (*Service, error) {
	var hosted HostedAdminConfig
	var socketPath string
	var registrationDelay time.Duration
	var actorPlane *remoting.Runtime
	useWebSocket := false
	for _, option := range options {
		switch value := option.(type) {
		case HostedAdminConfig:
			hosted = value
		case string:
			socketPath = value
		case registryTestDelay:
			registrationDelay = time.Duration(value)
		case *remoting.Runtime:
			actorPlane = value
		case websocketTransport:
			useWebSocket = true
		}
	}
	actorOptions := []actor.Option{actor.WithLogger(goaktlog.DefaultLogger), actor.WithPubSub(), actor.WithMessageRetention(5 * time.Minute)}
	guardianName := "service-guardian"
	if actorPlane != nil {
		if actorPlane.Remote == nil || actorPlane.NodeIdentity == "" {
			return nil, errors.New("remoting runtime is incomplete")
		}
		digest := sha256.Sum256([]byte(actorPlane.NodeIdentity))
		var incarnation [6]byte
		if _, err := rand.Read(incarnation[:]); err != nil {
			return nil, errors.New("generate cluster guardian incarnation")
		}
		guardianName = fmt.Sprintf("service-guardian-%x-%x", digest[:6], incarnation[:])
		if actorPlane.Cluster != nil {
			actorPlane.Cluster.WithKinds(&actors.ServiceGuardian{}, &actors.AgentActor{})
			actorOptions = append(actorOptions, actor.WithRemote(actorPlane.Remote), actor.WithCluster(actorPlane.Cluster), actor.WithoutRelocation())
		} else {
			actorOptions = append(actorOptions, actor.WithRemote(actorPlane.Remote), actor.WithoutRelocation())
		}
	}
	system, err := actor.NewActorSystem("workstation-subagents", actorOptions...)
	if err != nil {
		return nil, err
	}
	if err := system.Start(ctx); err != nil {
		return nil, err
	}
	fail := func(err error) (*Service, error) {
		stopCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = system.Stop(stopCtx)
		return nil, err
	}
	guardian, err := system.Spawn(ctx, guardianName, &actors.ServiceGuardian{}, actor.WithPassivationStrategy(passivation.NewLongLivedStrategy()))
	if err != nil {
		return fail(err)
	}
	sessions, err := guardian.SpawnChild(ctx, "session-registry", actors.NewSessionRegistryActor(), actor.WithMailbox(actor.NewNonBlockingBoundedMailbox(1024)), actor.WithPassivationStrategy(passivation.NewLongLivedStrategy()))
	if err != nil {
		return fail(err)
	}
	agents, err := guardian.SpawnChild(ctx, "agent-registry", actors.NewAgentRegistryActor(registrationDelay), actor.WithMailbox(actor.NewNonBlockingBoundedMailbox(1024)), actor.WithPassivationStrategy(passivation.NewLongLivedStrategy()))
	if err != nil {
		return fail(err)
	}
	coordinator, err := guardian.SpawnChild(ctx, "session-coordinator", actors.NewSessionCoordinator(sessions, agents), actor.WithMailbox(actor.NewNonBlockingBoundedMailbox(1024)), actor.WithPassivationStrategy(passivation.NewLongLivedStrategy()))
	if err != nil {
		return fail(err)
	}
	hostedSupervisor, err := guardian.SpawnChild(ctx, "hosted-runtime-supervisor", &actors.HostedRuntimeSupervisor{}, actor.WithMailbox(actor.NewNonBlockingBoundedMailbox(256)), actor.WithPassivationStrategy(passivation.NewLongLivedStrategy()))
	if err != nil {
		return fail(err)
	}
	workflowRegistry, err := guardian.SpawnChild(ctx, "workflow-registry", &actors.WorkflowRegistryActor{}, actor.WithMailbox(actor.NewNonBlockingBoundedMailbox(256)), actor.WithPassivationStrategy(passivation.NewLongLivedStrategy()))
	if err != nil {
		return fail(err)
	}
	taskCoordinator, err := guardian.SpawnChild(ctx, "task-coordinator", &actors.TaskCoordinatorActor{}, actor.WithMailbox(actor.NewNonBlockingBoundedMailbox(256)), actor.WithPassivationStrategy(passivation.NewLongLivedStrategy()))
	if err != nil {
		return fail(err)
	}
	var publicDirectory *actor.PID
	if actorPlane != nil {
		publicNodes := publicNodeMap(actorPlane)
		if hostedActorEndpoint(hosted) != "" {
			if endpoint, err := url.Parse(hostedActorEndpoint(hosted)); err == nil {
				if parsed, parseErr := strconv.Atoi(endpoint.Port()); parseErr == nil {
					for identity, node := range publicNodes {
						if node.ClientPort == 0 {
							node.ClientPort = parsed
							publicNodes[identity] = node
						}
					}
				}
			}
		}
		publicDirectory, err = guardian.SpawnChild(ctx, "public-agent-directory", actors.NewPublicAgentDirectoryActor(actorPlane.NodeIdentity, publicNodes), actor.WithMailbox(actor.NewNonBlockingBoundedMailbox(512)), actor.WithPassivationStrategy(passivation.NewLongLivedStrategy()))
		if err != nil {
			return fail(err)
		}
	}
	persistenceSupervisor, err := guardian.SpawnChild(ctx, "persistence-supervisor", &actors.PersistenceSupervisor{}, actor.WithMailbox(actor.NewNonBlockingBoundedMailbox(256)), actor.WithPassivationStrategy(passivation.NewLongLivedStrategy()))
	if err != nil {
		return fail(err)
	}
	var durableStore *durablestate.Store
	var persistencePID *actor.PID
	if hosted.Enabled || hosted.StateDirectory != "" {
		durableStore, err = durablestate.New(filepath.Join(hosted.StateDirectory, "registrations"))
		if err != nil {
			return fail(err)
		}
		persistencePID, err = guardian.SpawnChild(ctx, "hosted-state-writer", &actors.HostedStateWriterActor{Store: durableStore}, actor.WithMailbox(actor.NewNonBlockingBoundedMailbox(256)), actor.WithPassivationStrategy(passivation.NewLongLivedStrategy()), actor.WithSupervisor(supervisor.NewSupervisor(supervisor.WithAnyErrorDirective(supervisor.RestartDirective))))
		if err != nil {
			return fail(err)
		}
	}
	service := &Service{
		system: system, guardian: guardian, sessionRegistry: sessions, agentRegistry: agents, sessionCoordinator: coordinator, hostedSupervisor: hostedSupervisor, workflowRegistry: workflowRegistry, taskCoordinator: taskCoordinator, publicDirectory: publicDirectory, persistenceSupervisor: persistenceSupervisor, listener: listener, actorPlane: actorPlane,
		connectionSlots: make(chan struct{}, maxConnections), activeConnections: make(map[net.Conn]struct{}), requestResults: make(map[string]requestRecord), hostedRuntimes: make(map[string]*actor.PID), hostedRegistrations: make(map[string]hostedRegistration), hostedTerminal: make(map[string]application.HostedPiRuntimeBinding), hostedStartupFailure: make(map[string]string), hostedCleanup: make(map[string]hostedRegistration), hostedProjects: make(map[string]string), hostedStarting: make(map[string]int), registrationPlaceholders: make(map[string]*registrationPlaceholder), registrationCleanups: make(map[string]*registrationCleanup), hostedAdmin: hosted, socketPath: socketPath, hostedOperationCancels: make(map[uint64]context.CancelFunc), hostedAgentLocks: make(map[string]*sync.Mutex), registrationTimeout: requestTimeout, durableStore: durableStore, persistencePID: persistencePID, introspectionRunner: hosted.IntrospectionRunner, hostedIndeterminate: make(map[string]application.HostedPiRuntimeBinding), clientSessions: make(map[string]*actor.PID), publicSessionGenerations: make(map[string]string), pushSessions: make(map[*bridgePushSession]*actor.PID), rosterSessions: make(map[*clientRosterSession]*actor.PID), actorReplySessions: make(map[string]*actorReplySession), actorReplies: make(map[string][]actorReplyRecord), actorReplyNext: make(map[string]uint64),
	}
	if actorPlane != nil {
		placementAuthority := placementAuthorityName(actorPlane.NodeIdentity)
		_ = system.NoSender().Tell(ctx, agents, &application.ConfigurePublicAgentEvents{NodeIdentity: actorPlane.NodeIdentity, PlacementAuthority: placementAuthority, Epoch: uint64(time.Now().UnixNano())})
		if _, err := spawnPlacementAuthorityWithRetry(ctx, system, placementAuthority, &hostedPlacementAuthority{service: service}); err != nil {
			return fail(err)
		}
		service.connections.Add(1)
		go service.observeClusterEvents()
	}
	bridgeWatcher, err := guardian.SpawnChild(ctx, "bridge-session-watcher", &bridgeSessionWatcher{service: service}, actor.WithMailbox(actor.NewNonBlockingBoundedMailbox(256)), actor.WithPassivationStrategy(passivation.NewLongLivedStrategy()))
	if err != nil {
		return fail(err)
	}
	service.bridgeWatcher = bridgeWatcher
	if _, err := guardian.SpawnChild(ctx, "actor-reply-projection", &actorReplyBroker{service: service}, actor.WithMailbox(actor.NewBoundedMailbox(256)), actor.WithPassivationStrategy(passivation.NewLongLivedStrategy())); err != nil {
		return fail(err)
	}
	service.closeHostedSession = service.CloseSession
	service.removeHostedCredential = hostedpi.RemoveCredentialFile
	if hosted.Enabled {
		credential, readErr := hostedpi.ReadCredentialFile(hosted.AdminCredentialFile)
		if errors.Is(readErr, os.ErrNotExist) {
			credential = make([]byte, 32)
			if _, err := rand.Read(credential); err != nil {
				return fail(err)
			}
			if err := hostedpi.WriteCredentialFile(hosted.AdminCredentialFile, credential, true); err != nil {
				return fail(fmt.Errorf("bootstrap hosted admin credential: %w", err))
			}
		} else if readErr != nil {
			return fail(fmt.Errorf("read hosted admin credential: %w", readErr))
		}
		service.adminCredential = credential
		service.adminCredentialFile = hosted.AdminCredentialFile
		if err := service.reconcileDurableHosted(ctx); err != nil {
			return fail(fmt.Errorf("reconcile durable hosted state: %w", err))
		}
	}
	_ = system.NoSender().Tell(ctx, agents, &application.PublishPublicAgentSnapshot{})
	if actorPlane != nil && publicDirectory != nil {
		_ = system.ScheduleOnce(context.Background(), &application.PublicAgentSnapshotRequest{NodeIdentity: actorPlane.NodeIdentity}, publicDirectory, 250*time.Millisecond)
		_ = system.ScheduleOnce(context.Background(), &application.PublicAgentSnapshotRequest{NodeIdentity: actorPlane.NodeIdentity}, publicDirectory, time.Second)
	}
	service.connections.Add(1)
	if useWebSocket {
		go service.acceptWebSocketLoop()
	} else {
		go service.acceptLoop()
	}
	return service, nil
}

func (s *Service) observeClusterEvents() {
	defer s.connections.Done()
	subscriber, err := s.system.Subscribe()
	if err != nil {
		s.admissionMu.Lock()
		s.admissionErr = errors.Join(s.admissionErr, fmt.Errorf("subscribe cluster events: %w", err))
		s.admissionMu.Unlock()
		return
	}
	defer func() { _ = s.system.Unsubscribe(subscriber) }()
	for !s.stopping.Load() {
		for event := range subscriber.Iterator() {
			if _, ok := event.Payload().(*actor.NodeJoined); ok {
				_ = s.system.NoSender().Tell(context.Background(), s.agentRegistry, &application.PublishPublicAgentSnapshot{})
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func (s *Service) reconcileDurableHosted(ctx context.Context) error {
	records, quarantined, err := s.durableStore.LoadAllWithQuarantine(ctx)
	if err != nil {
		return err
	}
	for _, entry := range quarantined {
		// Per-record fail-closed quarantine: an invalid or unsafe durable entry
		// is moved aside and projected as degraded state instead of exiting the
		// daemon, so poisoned records can never crash-loop startup.
		s.reportDurableQuarantine(entry.Name, fmt.Sprintf("durable state entry quarantined: %s", entry.Reason))
	}
	for index := range records {
		record := records[index]
		if err := s.reconcileDurableRecord(ctx, record); err != nil {
			s.quarantineDurableRecord(ctx, record, err)
		}
	}
	return nil
}

// quarantineDurableRecord retires an unusable durable record fail-closed: the
// record file is moved aside for operator inspection, the persistence
// supervisor projects the degraded state, and the daemon keeps starting.
func (s *Service) quarantineDurableRecord(ctx context.Context, record application.DurableHostedRecord, cause error) {
	reason := fmt.Sprintf("durable hosted record %s quarantined: %v", record.AgentID, cause)
	if err := s.durableStore.Quarantine(record.AgentID, reason); err != nil {
		reason = fmt.Sprintf("%s (quarantine move failed: %v)", reason, err)
	}
	s.hostedMu.Lock()
	if s.hostedProjects[record.RuntimeConfig.ProjectDirectory] == record.AgentID {
		delete(s.hostedProjects, record.RuntimeConfig.ProjectDirectory)
	}
	s.hostedMu.Unlock()
	s.reportDurableQuarantine(record.AgentID, reason)
}

func (s *Service) reportDurableQuarantine(agentID, reason string) {
	if s.persistenceSupervisor != nil {
		_ = s.system.NoSender().Tell(context.Background(), s.persistenceSupervisor, &application.QuarantineDurableHostedState{AgentID: agentID, Reason: reason})
	}
}

func (s *Service) reconcileDurableRecord(ctx context.Context, record application.DurableHostedRecord) error {
	// Terminal records carry no hosted runtime, project, credential, or
	// ownership file: register them before any hosted path validation and
	// never let them reach ownership loading or stale-record removal.
	if record.AuthorityBinding.Kind != application.AuthorityBindingHostedOwned {
		// Heal legacy terminal records whose durable binding carries live
		// display metadata: the registry validator accepts only the pristine
		// inactive binding, while role and display name travel as registration
		// metadata. Without this the daemon rejects its own terminal records at
		// restart and crash-loops on "invalid agent registration".
		role, displayName := record.Binding.Role, record.Binding.DisplayName
		record.Binding = application.InactiveHostedPiRuntimeBinding()
		registration := application.RegisterAgent{AgentID: record.AgentID, Role: role, DisplayName: displayName, AuthorityBinding: record.AuthorityBinding, HostedPiRuntime: record.Binding, AllowedCapability: append([]string(nil), record.AllowedCapabilities...), Retention: record.Retention, Recovery: record.Recovery, PersistencePID: s.persistencePID, PersistenceSupervisor: s.persistenceSupervisor, IntrospectionRunner: s.introspectionRunner, DurableRecord: &record}
		if _, err := s.registerAgent(ctx, registration, hostedRegistration{}); err != nil {
			return fmt.Errorf("register durable terminal agent %s: %w", record.AgentID, err)
		}
		return nil
	}
	s.hostedMu.Lock()
	if record.RuntimeConfig.ProjectDirectory != "" {
		if owner := s.hostedProjects[record.RuntimeConfig.ProjectDirectory]; owner != "" && owner != record.AgentID {
			s.hostedMu.Unlock()
			return fmt.Errorf("durable hosted worktree is shared by %s and %s", owner, record.AgentID)
		}
		s.hostedProjects[record.RuntimeConfig.ProjectDirectory] = record.AgentID
	}
	s.hostedMu.Unlock()
	if !pathWithin(record.Session.CredentialFile, s.hostedAdmin.CredentialDirectory) || !pathWithin(record.LaunchSpec.PiSessionDirectory, s.hostedAdmin.PiSessionDirectory) {
		return fmt.Errorf("durable hosted %s escaped configured private roots", record.AgentID)
	}
	if err := validateProjectDirectory(record.RuntimeConfig.ProjectDirectory); err != nil {
		return fmt.Errorf("durable hosted %s project: %w", record.AgentID, err)
	}
	credential, err := hostedpi.ReadCredentialFile(record.Session.CredentialFile)
	if err != nil {
		return fmt.Errorf("durable hosted %s credential: %w", record.AgentID, err)
	}
	binding := record.Binding
	if binding.TmuxSessionID == "" {
		binding, err = hostedpi.LoadOwnershipBinding(s.hostedAdmin.StateDirectory, record.LaunchSpec.RuntimeID)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				if removeErr := s.removeStaleDurable(ctx, record); removeErr != nil {
					return removeErr
				}
				return nil
			}
			return fmt.Errorf("durable hosted %s ownership record: %w", record.AgentID, err)
		}
	}
	runtimeConfig := hostedpi.Config{TmuxBinary: s.hostedAdmin.TmuxBinary, PiBinary: s.hostedAdmin.PiBinary, BridgeExtension: s.hostedAdmin.BridgeExtension, DaemonEndpoint: hostedActorEndpoint(s.hostedAdmin), CredentialFile: record.Session.CredentialFile, ServerName: s.hostedAdmin.ServerName, TmuxConfig: s.hostedAdmin.TmuxConfig, ProjectDirectory: record.RuntimeConfig.ProjectDirectory, StateDirectory: s.hostedAdmin.StateDirectory, SessionID: record.Session.SessionID, GenerationID: record.Session.GenerationID, CallerIdentity: record.Session.Caller, TrustProject: record.RuntimeConfig.TrustProject}
	runtime := &hostedpi.Runtime{Config: runtimeConfig}
	process, adoptErr := runtime.Adopt(ctx, record.LaunchSpec, binding)
	if errors.Is(adoptErr, hostedpi.ErrRuntimeAbsent) {
		if err := s.removeStaleDurable(ctx, record); err != nil {
			return err
		}
		return nil
	}
	if adoptErr != nil {
		binding.State = application.HostedPiRuntimeDegraded
		binding.BridgeReady = false
		binding.OwnershipIndeterminate = true
		s.hostedMu.Lock()
		s.hostedTerminal[record.AgentID] = binding
		s.hostedIndeterminate[record.AgentID] = binding
		s.hostedRegistrations[record.AgentID] = hostedRegistration{sessionID: record.Session.SessionID, credentialFile: record.Session.CredentialFile}
		s.hostedMu.Unlock()
		return nil
	}
	binding.State = application.HostedPiRuntimeStarting
	binding.BridgeReady = false
	record.Binding = binding
	session := application.OpenSession{SessionID: record.Session.SessionID, GenerationID: record.Session.GenerationID, Caller: record.Session.Caller, Credential: credential, Capabilities: append([]string(nil), record.Session.Capabilities...), ExpiresAt: record.Session.ExpiresAt, Persistent: record.Session.Persistent}
	if !session.Persistent {
		return fmt.Errorf("durable hosted %s uses an expiring legacy session", record.AgentID)
	}
	if err := s.OpenSession(ctx, session); err != nil {
		return fmt.Errorf("reopen durable hosted session %s: %w", record.AgentID, err)
	}
	registration := application.RegisterAgent{AgentID: record.AgentID, Role: binding.Role, DisplayName: binding.DisplayName, AuthorityBinding: record.AuthorityBinding, HostedPiRuntime: binding, AllowedCapability: append([]string(nil), record.AllowedCapabilities...), PhaseTwoOwned: true, Retention: record.Retention, Recovery: record.Recovery, Runtime: runtime, LaunchSpec: record.LaunchSpec, RuntimeStartTimeout: requestTimeout, AdoptedProcess: process, PersistencePID: s.persistencePID, PersistenceSupervisor: s.persistenceSupervisor, IntrospectionRunner: s.introspectionRunner, DurableRecord: &record}
	result, err := s.registerAgent(ctx, registration, hostedRegistration{sessionID: session.SessionID, credentialFile: record.Session.CredentialFile})
	if err != nil {
		return fmt.Errorf("register adopted hosted agent %s: %w", record.AgentID, err)
	}
	s.hostedMu.Lock()
	s.hostedRuntimes[record.AgentID] = result.AgentPID
	s.hostedRegistrations[record.AgentID] = hostedRegistration{sessionID: session.SessionID, credentialFile: record.Session.CredentialFile}
	s.hostedMu.Unlock()
	barrier, err := s.durableBarrier(ctx, result.AgentPID)
	if err != nil {
		return err
	}
	if !barrier.Completed {
		return fmt.Errorf("adopted durable publication failed: %s", barrier.Reason)
	}
	return nil
}

func (s *Service) removeStaleDurable(ctx context.Context, record application.DurableHostedRecord) error {
	defer func() {
		s.hostedMu.Lock()
		if s.hostedProjects[record.RuntimeConfig.ProjectDirectory] == record.AgentID {
			delete(s.hostedProjects, record.RuntimeConfig.ProjectDirectory)
		}
		s.hostedMu.Unlock()
	}()
	if err := hostedpi.RemoveOwnershipRecord(s.hostedAdmin.StateDirectory, record.LaunchSpec.RuntimeID); err != nil {
		return err
	}
	if err := hostedpi.RemoveCredentialFile(record.Session.CredentialFile); err != nil {
		return err
	}
	return s.durableStore.Remove(ctx, record.AgentID)
}
func pathWithin(path, root string) bool {
	clean, base := filepath.Clean(path), filepath.Clean(root)
	relative, err := filepath.Rel(base, clean)
	return err == nil && relative != "." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) && !filepath.IsAbs(relative)
}

func (s *Service) durableBarrier(ctx context.Context, pid *actor.PID) (application.OperationResult, error) {
	results := make(chan application.OperationResult, 1)
	if err := s.system.NoSender().Tell(ctx, pid, &application.DurableBarrier{Result: results}); err != nil {
		return application.OperationResult{}, err
	}
	select {
	case result := <-results:
		return result, nil
	case <-ctx.Done():
		return application.OperationResult{}, ctx.Err()
	}
}

func (s *Service) Health(ctx context.Context) (application.HealthState, error) {
	response, err := s.system.NoSender().Ask(ctx, s.guardian, &application.Health{}, requestTimeout)
	if err != nil {
		return application.HealthState{}, err
	}
	health, ok := response.(*application.HealthState)
	if !ok {
		return application.HealthState{}, errors.New("unexpected health response")
	}
	result := *health
	s.hostedMu.Lock()
	indeterminate := len(s.hostedIndeterminate) != 0
	s.hostedMu.Unlock()
	if indeterminate {
		result.Ready = false
		result.Status = "durable hosted ownership is indeterminate"
	}
	if result.Ready && s.persistenceSupervisor != nil {
		// Durable quarantine is fail-closed: health derives from the live
		// quarantine projection rather than continuing as if persistence were
		// reliable after a record was moved aside or a wipe was refused.
		if value, err := s.system.NoSender().Ask(ctx, s.persistenceSupervisor, &application.DurableQuarantineStatus{}, requestTimeout); err == nil {
			if state, ok := value.(*application.DurableQuarantineState); ok && state.FailClosed {
				ids := make([]string, 0, len(state.Items))
				for id := range state.Items {
					ids = append(ids, id)
				}
				slices.Sort(ids)
				result.Ready = false
				result.Status = "durable hosted state quarantined: " + strings.Join(ids, ",")
			}
		}
	}
	return result, nil
}

func (s *Service) OpenSession(ctx context.Context, session application.OpenSession) error {
	results := make(chan application.CoordinationResult, 1)
	if err := s.system.NoSender().Tell(ctx, s.sessionCoordinator, &application.CoordinateOpen{Session: session, Result: results}); err != nil {
		return err
	}
	timer := time.NewTimer(requestTimeout)
	defer timer.Stop()
	select {
	case result := <-results:
		if !result.Allowed {
			return errors.New("session registration rejected")
		}
		if s.publicDirectory != nil {
			s.clientSessionMu.Lock()
			s.publicSessionGenerations[session.SessionID] = session.GenerationID
			s.clientSessionMu.Unlock()
			_ = s.system.NoSender().Tell(ctx, s.publicDirectory, &application.StageSession{Session: session, Registry: application.AgentRegistry})
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return errors.New("session registration coordination timed out")
	}
}

func (s *Service) CloseSession(ctx context.Context, sessionID string) error {
	results := make(chan application.CoordinationResult, 1)
	if err := s.system.NoSender().Tell(ctx, s.sessionCoordinator, &application.CoordinateClose{SessionID: sessionID, Result: results}); err != nil {
		return err
	}
	timer := time.NewTimer(requestTimeout)
	defer timer.Stop()
	select {
	case result := <-results:
		if !result.Completed {
			return errors.New("session cleanup did not complete")
		}
		if s.publicDirectory != nil {
			s.clientSessionMu.Lock()
			generation := s.publicSessionGenerations[sessionID]
			delete(s.publicSessionGenerations, sessionID)
			s.clientSessionMu.Unlock()
			_ = s.system.NoSender().Tell(ctx, s.publicDirectory, &application.CommitSessionClose{SessionID: sessionID, GenerationID: generation, Registry: application.AgentRegistry})
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return errors.New("session cleanup coordination timed out")
	}
}

func (s *Service) RegisterAgent(ctx context.Context, registration application.RegisterAgent) error {
	operationCtx, finish, err := s.beginHostedOperation(ctx)
	if err != nil {
		return err
	}
	defer finish()
	lock := s.hostedAgentLock(registration.AgentID)
	lock.Lock()
	defer lock.Unlock()
	result, registrationErr := s.registerAgent(operationCtx, registration)
	if result != nil && result.RuntimePID != nil && !result.CleanupPending {
		s.hostedMu.Lock()
		if s.stopping.Load() {
			s.hostedMu.Unlock()
			cleanupCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			return s.rollbackHostedRegistration(cleanupCtx, registration.AgentID, result.RuntimePID, hostedRegistration{})
		}
		s.hostedRuntimes[registration.AgentID] = result.AgentPID
		s.hostedMu.Unlock()
	}
	return registrationErr
}

func (s *Service) registerAgent(ctx context.Context, registration application.RegisterAgent, cleanupMetadata ...hostedRegistration) (*application.RegisterAgentResult, error) {
	operationID, err := randomHandle()
	if err != nil {
		return nil, err
	}
	metadata := hostedRegistration{}
	if len(cleanupMetadata) > 0 {
		metadata = cleanupMetadata[0]
	}
	placeholder := &registrationPlaceholder{operationID: operationID, agentID: registration.AgentID, registration: registration, metadata: metadata, outcome: make(chan application.RegisterAgentResult, 1), compensation: make(chan application.UnregisterAgentResult, 1), done: make(chan struct{})}
	// Publish the service-owned reconciliation placeholder before mutation Tell.
	s.hostedMu.Lock()
	s.registrationPlaceholders[operationID] = placeholder
	s.hostedMu.Unlock()
	if registration.PersistenceSupervisor == nil {
		registration.PersistenceSupervisor = s.persistenceSupervisor
	}
	request := &application.CoordinateAgentRegistration{OperationID: operationID, Registration: registration, Result: placeholder.outcome}
	if err := s.system.NoSender().Tell(ctx, s.agentRegistry, request); err != nil {
		s.hostedMu.Lock()
		delete(s.registrationPlaceholders, operationID)
		s.hostedMu.Unlock()
		close(placeholder.done)
		return nil, err
	}
	timer := time.NewTimer(s.registrationTimeout)
	defer timer.Stop()
	var waitErr error
	select {
	case result := <-placeholder.outcome:
		_ = s.system.NoSender().Tell(context.WithoutCancel(ctx), s.agentRegistry, &application.ConfirmAgentRegistration{OperationID: operationID})
		s.hostedMu.Lock()
		delete(s.registrationPlaceholders, operationID)
		s.hostedMu.Unlock()
		close(placeholder.done)
		if !result.Created {
			return nil, errors.New(result.Reason)
		}
		return &result, nil
	case <-ctx.Done():
		waitErr = ctx.Err()
	case <-timer.C:
		waitErr = errors.New("agent registration coordination timed out")
	}
	// The watcher owns both original outcome and ordered compensation forever;
	// foreground timeout cannot abandon a delayed created PID.
	go s.watchRegistrationPlaceholder(placeholder)
	return &application.RegisterAgentResult{CleanupPending: true, CleanupID: operationID}, waitErr
}

func (s *Service) watchRegistrationPlaceholder(placeholder *registrationPlaceholder) {
	var err error
	for {
		if err = s.system.NoSender().Tell(context.Background(), s.agentRegistry, &application.CompensateAgentRegistration{OperationID: placeholder.operationID, AgentID: placeholder.agentID, Result: placeholder.compensation}); err == nil {
			break
		}
		s.hostedMu.Lock()
		placeholder.lastErr = err
		s.hostedMu.Unlock()
		time.Sleep(10 * time.Millisecond)
	}
	outcome := <-placeholder.outcome
	for {
		compensation := <-placeholder.compensation
		if compensation.Completed && (!outcome.Created || compensation.AgentPID != nil) {
			if !outcome.Created {
				binding := placeholder.registration.HostedPiRuntime
				binding.CleanupPending = true
				cleanup := &registrationCleanup{operationID: placeholder.operationID, agentID: placeholder.agentID, metadata: placeholder.metadata, binding: binding, removeDurable: placeholder.registration.DurableRecord != nil}
				s.hostedMu.Lock()
				delete(s.registrationPlaceholders, placeholder.operationID)
				s.registrationCleanups[placeholder.operationID] = cleanup
				s.hostedMu.Unlock()
				_ = s.system.NoSender().Tell(context.Background(), s.agentRegistry, &application.AcknowledgeAgentRegistrationTracking{OperationID: placeholder.operationID})
				close(placeholder.done)
				go s.runRegistrationCleanup(placeholder.operationID, cleanup)
				return
			}
			binding := placeholder.registration.HostedPiRuntime
			binding.CleanupPending = true
			cleanup := &registrationCleanup{operationID: placeholder.operationID, agentID: placeholder.agentID, agentPID: compensation.AgentPID, runtimePID: compensation.RuntimePID, metadata: placeholder.metadata, binding: binding, removeDurable: placeholder.registration.DurableRecord != nil}
			s.hostedMu.Lock()
			delete(s.registrationPlaceholders, placeholder.operationID)
			s.registrationCleanups[placeholder.operationID] = cleanup
			s.hostedMu.Unlock()
			_ = s.system.NoSender().Tell(context.Background(), s.agentRegistry, &application.AcknowledgeAgentRegistrationTracking{OperationID: placeholder.operationID})
			close(placeholder.done)
			go s.runRegistrationCleanup(placeholder.operationID, cleanup)
			return
		}
		s.hostedMu.Lock()
		placeholder.lastErr = errors.New(compensation.Reason)
		s.hostedMu.Unlock()
		time.Sleep(10 * time.Millisecond)
		_ = s.system.NoSender().Tell(context.Background(), s.agentRegistry, &application.CompensateAgentRegistration{OperationID: placeholder.operationID, AgentID: placeholder.agentID, Result: placeholder.compensation})
	}
}

func (s *Service) runRegistrationCleanup(operationID string, cleanup *registrationCleanup) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_ = s.attemptRegistrationCleanup(ctx, operationID, cleanup)
}

func (s *Service) attemptRegistrationCleanup(ctx context.Context, operationID string, cleanup *registrationCleanup) error {
	for !cleanup.mu.TryLock() {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(10 * time.Millisecond):
		}
	}
	defer cleanup.mu.Unlock()
	if !cleanup.runtimeStopped && cleanup.runtimePID != nil {
		if err := s.requestHostedRuntimeStop(ctx, cleanup.runtimePID, "registration timeout compensation", boundedRemaining(ctx, 10*time.Second)); err != nil {
			cleanup.lastErr = err
			return err
		}
		for {
			value, err := s.system.NoSender().Ask(ctx, cleanup.runtimePID, &application.HostedPiRuntimeStatus{}, min(requestTimeout, boundedRemaining(ctx, requestTimeout)))
			if err != nil {
				cleanup.lastErr = err
				return err
			}
			binding, ok := value.(*application.HostedPiRuntimeBinding)
			if !ok {
				err = errors.New("unexpected registration cleanup runtime status")
				cleanup.lastErr = err
				return err
			}
			cleanup.binding = *binding
			cleanup.binding.CleanupPending = true
			if binding.OwnershipIndeterminate {
				cleanup.lastErr = application.ErrHostedOwnershipIndeterminate
				return cleanup.lastErr
			}
			if binding.State == application.HostedPiRuntimeStopped {
				cleanup.runtimeStopped = true
				break
			}
			if binding.State == application.HostedPiRuntimeDegraded {
				cleanup.lastErr = errors.New("registration cleanup runtime is degraded without process-death proof")
				return cleanup.lastErr
			}
			select {
			case <-ctx.Done():
				cleanup.lastErr = ctx.Err()
				return cleanup.lastErr
			case <-time.After(10 * time.Millisecond):
			}
		}
	}
	if !cleanup.agentStopped && cleanup.agentPID != nil {
		if err := cleanup.agentPID.Shutdown(ctx); err != nil {
			cleanup.lastErr = err
			return err
		}
		cleanup.agentStopped = true
	}
	if cleanup.metadata.sessionID != "" {
		if err := s.closeHostedSession(ctx, cleanup.metadata.sessionID); err != nil {
			cleanup.lastErr = err
			return err
		}
		cleanup.metadata.sessionID = ""
	}
	if cleanup.metadata.credentialFile != "" {
		if err := s.removeHostedCredential(cleanup.metadata.credentialFile); err != nil {
			cleanup.lastErr = err
			return err
		}
		cleanup.metadata.credentialFile = ""
	}
	if cleanup.removeDurable && s.durableStore != nil {
		if err := s.durableStore.Remove(ctx, cleanup.agentID); err != nil {
			cleanup.lastErr = err
			return err
		}
		cleanup.removeDurable = false
	}
	cleanup.lastErr = nil
	s.hostedMu.Lock()
	if s.registrationCleanups[operationID] == cleanup {
		delete(s.registrationCleanups, operationID)
	}
	s.hostedMu.Unlock()
	return nil
}

func (s *Service) stopRegistrationPlaceholders(ctx context.Context) error {
	for {
		s.hostedMu.Lock()
		pending := make([]*registrationPlaceholder, 0, len(s.registrationPlaceholders))
		for _, item := range s.registrationPlaceholders {
			pending = append(pending, item)
		}
		s.hostedMu.Unlock()
		if len(pending) == 0 {
			return nil
		}
		for _, item := range pending {
			select {
			case <-item.done:
			case <-ctx.Done():
				return fmt.Errorf("wait registration PID reconciliation: %w", ctx.Err())
			}
		}
	}
}

func (s *Service) stopRegistrationCleanups(ctx context.Context) error {
	for {
		s.hostedMu.Lock()
		items := make(map[string]*registrationCleanup, len(s.registrationCleanups))
		for id, item := range s.registrationCleanups {
			items[id] = item
		}
		s.hostedMu.Unlock()
		if len(items) == 0 {
			return nil
		}
		var attemptErr error
		for id, item := range items {
			if err := s.attemptRegistrationCleanup(ctx, id, item); err != nil {
				attemptErr = errors.Join(attemptErr, err)
			}
		}
		if attemptErr == nil {
			continue
		}
		select {
		case <-ctx.Done():
			return errors.Join(attemptErr, ctx.Err())
		case <-time.After(10 * time.Millisecond):
		}
	}
}

// Stop is retryable while registration cleanup or projection quiescence remains
// unproven. Exactly owned hosted tmux/Pi processes survive daemon shutdown so a
// replacement daemon can revalidate and adopt them; explicit actor STOP remains
// the only path that destroys a stable hosted runtime.
func (s *Service) Stop(ctx context.Context) error {
	s.stopMu.Lock()
	defer s.stopMu.Unlock()
	if s.stopped {
		return s.stopResult
	}
	s.hostedMu.Lock()
	preserve := make(map[string]struct{}, len(s.hostedRuntimes))
	for id := range s.hostedRuntimes {
		if s.hostedStarting[id] == 0 {
			preserve[id] = struct{}{}
		}
	}
	s.hostedMu.Unlock()
	s.hostedOperationMu.Lock()
	s.stopping.Store(true)
	for _, cancel := range s.hostedOperationCancels {
		cancel()
	}
	operationsDone := s.hostedOperationDone
	s.hostedOperationMu.Unlock()
	s.connectionMu.Lock()
	closeErr := s.listener.Close()
	if errors.Is(closeErr, net.ErrClosed) {
		closeErr = nil
	}
	for connection := range s.activeConnections {
		_ = connection.Close()
	}
	s.connectionMu.Unlock()
	var operationErr error
	if operationsDone != nil {
		select {
		case <-operationsDone:
		case <-ctx.Done():
			operationErr = fmt.Errorf("wait hosted operations: %w", ctx.Err())
		}
	}
	placeholderErr := s.stopRegistrationPlaceholders(ctx)
	if placeholderErr != nil {
		s.stopResult = errors.Join(operationErr, placeholderErr, closeErr)
		return s.stopResult
	}
	registrationErr := s.stopRegistrationCleanups(ctx)
	if registrationErr != nil {
		s.stopResult = errors.Join(operationErr, registrationErr, closeErr)
		return s.stopResult
	}
	s.hostedMu.Lock()
	transient := make(map[string]struct{})
	for id := range s.hostedRuntimes {
		if _, stable := preserve[id]; !stable {
			transient[id] = struct{}{}
		}
	}
	s.hostedMu.Unlock()
	if transientErr := s.stopHostedRuntimes(ctx, transient); transientErr != nil {
		s.stopResult = errors.Join(operationErr, transientErr, closeErr)
		return s.stopResult
	}
	hostedErr := s.quiesceHostedRuntimes(ctx)
	if hostedErr != nil {
		s.stopResult = errors.Join(operationErr, hostedErr, closeErr)
		return s.stopResult
	}
	connectionsDone := make(chan struct{})
	go func() { s.connections.Wait(); close(connectionsDone) }()
	var waitErr error
	select {
	case <-ctx.Done():
		waitErr = ctx.Err()
	case <-connectionsDone:
	}
	if waitErr != nil {
		s.stopResult = errors.Join(operationErr, waitErr, closeErr)
		return s.stopResult
	}
	stopErr := s.system.Stop(ctx)
	if stopErr != nil {
		s.stopResult = errors.Join(operationErr, stopErr, closeErr)
		return s.stopResult
	}
	var adminErr error
	if s.adminCredentialFile != "" {
		adminErr = hostedpi.RemoveCredentialFile(s.adminCredentialFile)
	}
	s.admissionMu.Lock()
	admissionErr := s.admissionErr
	s.admissionMu.Unlock()
	s.stopResult = errors.Join(operationErr, closeErr, admissionErr, adminErr)
	s.stopped = true
	return s.stopResult
}

func (s *Service) requestHostedRuntimeStop(ctx context.Context, pid *actor.PID, reason string, timeout time.Duration) error {
	accepted := make(chan application.OperationResult, 1)
	if err := s.system.NoSender().Tell(ctx, pid, &application.StopHostedPiRuntime{Reason: reason, Timeout: timeout, Accepted: accepted}); err != nil {
		return err
	}
	select {
	case result := <-accepted:
		if !result.Completed {
			if result.Reason == "" {
				result.Reason = "hosted runtime stop was not admitted"
			}
			return errors.New(result.Reason)
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(min(requestTimeout, timeout)):
		return errors.New("hosted runtime stop admission timed out")
	}
}

func (s *Service) quiesceHostedRuntimes(ctx context.Context) error {
	s.hostedMu.Lock()
	runtimes := make(map[string]*actor.PID, len(s.hostedRuntimes))
	for id, pid := range s.hostedRuntimes {
		runtimes[id] = pid
	}
	s.hostedMu.Unlock()
	for _, pid := range runtimes {
		if err := s.system.NoSender().Tell(ctx, pid, &application.HostedPiBridgeReadiness{Ready: false}); err != nil {
			return err
		}
	}
	for id, pid := range runtimes {
		for {
			if err := ctx.Err(); err != nil {
				return err
			}
			value, err := s.system.NoSender().Ask(ctx, pid, &application.HostedPiRuntimeStatus{}, requestTimeout)
			if err != nil {
				return fmt.Errorf("read hosted runtime %s quiescence state: %w", id, err)
			}
			binding, ok := value.(*application.HostedPiRuntimeBinding)
			if !ok {
				return fmt.Errorf("read hosted runtime %s quiescence state: unexpected response", id)
			}
			if !binding.BridgeReady {
				barrier, err := s.durableBarrier(ctx, pid)
				if err != nil {
					return fmt.Errorf("persist hosted runtime %s quiescence: %w", id, err)
				}
				if !barrier.Completed {
					return fmt.Errorf("persist hosted runtime %s quiescence: %s", id, barrier.Reason)
				}
				break
			}
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(10 * time.Millisecond):
			}
		}
	}
	return nil
}

func (s *Service) stopHostedRuntimes(ctx context.Context, only map[string]struct{}) error {
	s.hostedMu.Lock()
	runtimes := make(map[string]*actor.PID, len(s.hostedRuntimes))
	for id, pid := range s.hostedRuntimes {
		if _, selected := only[id]; selected {
			runtimes[id] = pid
		}
	}
	s.hostedMu.Unlock()
	for _, pid := range runtimes {
		if err := s.requestHostedRuntimeStop(ctx, pid, "daemon shutdown", boundedRemaining(ctx, 5*time.Second)); err != nil {
			return err
		}
	}
	for id, pid := range runtimes {
		for {
			if err := ctx.Err(); err != nil {
				return err
			}
			value, err := s.system.NoSender().Ask(ctx, pid, &application.HostedPiRuntimeStatus{}, requestTimeout)
			if err != nil {
				return fmt.Errorf("read hosted runtime %s shutdown state: %w", id, err)
			}
			binding, ok := value.(*application.HostedPiRuntimeBinding)
			if !ok {
				return fmt.Errorf("read hosted runtime %s shutdown state: unexpected response", id)
			}
			if binding.State == application.HostedPiRuntimeStopped {
				s.hostedMu.Lock()
				metadata := s.hostedRegistrations[id]
				s.hostedMu.Unlock()
				if err := s.unregisterHostedAgent(ctx, id); err != nil {
					return fmt.Errorf("unregister hosted agent %s: %w", id, err)
				}
				if err := s.retireStoppedRuntime(id, pid, *binding, metadata); err != nil {
					return fmt.Errorf("retire hosted agent %s: %w", id, err)
				}
				break
			}
			if binding.State == application.HostedPiRuntimeDegraded {
				return fmt.Errorf("hosted runtime %s cleanup degraded", id)
			}
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(10 * time.Millisecond):
			}
		}
	}
	for {
		s.hostedMu.Lock()
		pending := make([]string, 0, len(s.hostedCleanup))
		for id := range s.hostedCleanup {
			pending = append(pending, id)
		}
		s.hostedMu.Unlock()
		if len(pending) == 0 {
			return nil
		}
		var cleanupErr error
		for _, id := range pending {
			if err := s.cleanupHostedMetadata(ctx, id); err != nil {
				cleanupErr = errors.Join(cleanupErr, fmt.Errorf("cleanup hosted agent %s: %w", id, err))
			}
		}
		if cleanupErr == nil {
			continue
		}
		select {
		case <-ctx.Done():
			return errors.Join(cleanupErr, ctx.Err())
		case <-time.After(10 * time.Millisecond):
		}
	}
}

func (s *Service) acceptLoop() {
	defer s.connections.Done()
	temporaryFailures := 0
	for {
		connection, err := s.listener.Accept()
		if err != nil {
			if s.stopping.Load() || errors.Is(err, net.ErrClosed) {
				return
			}
			if temporary, ok := err.(interface{ Temporary() bool }); ok && temporary.Temporary() && temporaryFailures < maxTemporaryAcceptRetries {
				temporaryFailures++
				time.Sleep(time.Duration(temporaryFailures) * 10 * time.Millisecond)
				continue
			}
			s.markAdmissionFailure(fmt.Errorf("accept admission: %w", err))
			return
		}
		temporaryFailures = 0
		s.acceptStreamConnection(connection)
	}
}

func (s *Service) markAdmissionFailure(err error) {
	s.admissionMu.Lock()
	if s.admissionErr == nil {
		s.admissionErr = err
	}
	s.admissionMu.Unlock()
	s.system.NoSender().Tell(context.Background(), s.guardian, &application.SetHealth{Ready: false, Status: "admission degraded"})
}

func (s *Service) handleConnection(connection net.Conn) {
	writer := make(chan *subagentsv1.Envelope, 32)
	closed := make(chan struct{})
	var pushSession *bridgePushSession
	var rosterSession *clientRosterSession
	var actorReplyKey [3]string
	writerDone := make(chan struct{})
	go func() {
		defer close(writerDone)
		for envelope := range writer {
			_ = connection.SetWriteDeadline(time.Now().Add(30 * time.Second))
			if err := protocol.WriteEnvelope(connection, envelope); err != nil {
				_ = connection.Close()
				return
			}
		}
	}()
	defer func() {
		close(closed)
		if pushSession != nil {
			s.unregisterBridgePush(pushSession)
		}
		if rosterSession != nil {
			s.unregisterClientRoster(rosterSession)
		}
		if actorReplyKey[0] != "" {
			s.unregisterActorReplySession(actorReplyKey[0], actorReplyKey[1], actorReplyKey[2])
		}
		close(writer)
		<-writerDone
		s.connectionMu.Lock()
		delete(s.activeConnections, connection)
		s.connectionMu.Unlock()
		_ = connection.Close()
	}()
	replay := connectionReplay{entries: make(map[uint64]sequenceRecord)}
	for {
		_ = connection.SetReadDeadline(time.Now().Add(30 * time.Second))
		envelope, err := protocol.ReadEnvelope(connection)
		if err != nil {
			return
		}
		responseDeadline := time.UnixMilli(envelope.DeadlineUnixMillis).Add(time.Second)
		if maximum := time.Now().Add(6 * time.Hour); responseDeadline.After(maximum) {
			responseDeadline = maximum
		}
		_ = connection.SetReadDeadline(responseDeadline)
		response := s.sequenceResponse(&replay, envelope)
		if !enqueueFrame(writer, response, responseDeadline) {
			return
		}
		if _, ok := authenticatedClientSource(envelope.CallerIdentity); ok && response.GetProtocolError() == nil {
			actorReplyKey = [3]string{envelope.SessionId, envelope.GenerationId, envelope.CallerIdentity}
			s.registerActorReplySession(envelope, writer, closed)
		}
		if next := s.bridgePushRegistration(envelope, response, writer, closed); next != nil {
			if pushSession != nil {
				s.unregisterBridgePush(pushSession)
			}
			pushSession = next
			s.registerBridgePush(next)
		}
		if next := s.clientRosterRegistration(envelope, response, writer, closed); next != nil {
			if rosterSession != nil {
				s.unregisterClientRoster(rosterSession)
			}
			rosterSession = next
			s.registerClientRoster(next)
		}
	}
}

func enqueueFrame(writer chan<- *subagentsv1.Envelope, envelope *subagentsv1.Envelope, deadline time.Time) bool {
	if envelope == nil {
		return true
	}
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()
	select {
	case writer <- envelope:
		return true
	case <-timer.C:
		return false
	}
}

func (s *Service) clientRosterRegistration(request, response *subagentsv1.Envelope, writer chan<- *subagentsv1.Envelope, closed <-chan struct{}) *clientRosterSession {
	payload, ok := request.Payload.(*subagentsv1.Envelope_ClientAgentRosterRequest)
	operation := response.GetAgentOperationResponse()
	if !ok || operation == nil || !operation.Completed || operation.Reason != "" {
		return nil
	}
	return &clientRosterSession{sessionID: request.SessionId, generationID: request.GenerationId, principal: request.CallerIdentity, credential: append([]byte(nil), request.SessionCredential...), lastEpoch: payload.ClientAgentRosterRequest.LastEpoch, afterSequence: payload.ClientAgentRosterRequest.AfterSequence, writer: writer, closed: closed}
}

func (s *Service) registerClientRoster(session *clientRosterSession) {
	suffix, suffixErr := randomHandle()
	if suffixErr != nil {
		suffix = fmt.Sprint(time.Now().UnixNano())
	}
	pid, err := s.guardian.SpawnChild(context.Background(), "client-roster-session-"+session.sessionID+"-"+suffix, newClientRosterActor(s, session), actor.WithMailbox(actor.NewNonBlockingBoundedMailbox(128)), actor.WithPassivationStrategy(passivation.NewLongLivedStrategy()))
	if err != nil || pid == nil {
		return
	}
	s.rosterMu.Lock()
	s.rosterSessions[session] = pid
	s.rosterMu.Unlock()
	if err := s.system.NoSender().Tell(context.Background(), pid, &clientRosterFlush{}); err != nil {
		s.unregisterClientRoster(session)
	}
}

func (s *Service) unregisterClientRoster(session *clientRosterSession) {
	s.rosterMu.Lock()
	pid := s.rosterSessions[session]
	delete(s.rosterSessions, session)
	s.rosterMu.Unlock()
	if pid != nil {
		_ = s.system.NoSender().Tell(context.Background(), pid, &clientRosterClosed{})
		_ = pid.Shutdown(context.Background())
	}
}

func (s *Service) removeClientRosterActorName(name string) {
	s.rosterMu.Lock()
	defer s.rosterMu.Unlock()
	for session, current := range s.rosterSessions {
		if current != nil && current.Name() == name {
			delete(s.rosterSessions, session)
		}
	}
}

func (s *Service) pushClientRosterToSession(session *clientRosterSession, events []application.ClientAgentRosterEvent) bool {
	session.mu.Lock()
	defer session.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), requestTimeout)
	defer cancel()
	value, err := s.system.NoSender().Ask(ctx, s.sessionRegistry, &application.SessionAuthorization{SessionID: session.sessionID, GenerationID: session.generationID, Caller: session.principal, Credential: session.credential, Capability: "observe"}, requestTimeout)
	if err != nil {
		return false
	}
	result, ok := value.(*application.AuthorizationResult)
	if !ok || !result.Allowed {
		return false
	}
	frames := make([]*subagentsv1.Envelope, 0, len(events))
	for _, event := range events {
		if event.Operation == "" || (event.Epoch < session.lastEpoch || event.Epoch == session.lastEpoch && event.Sequence <= session.afterSequence) {
			continue
		}
		frames = append(frames, &subagentsv1.Envelope{ProtocolMajor: protocol.ProtocolMajor, ProtocolMinor: protocol.ProtocolMinor, Payload: &subagentsv1.Envelope_ClientAgentRosterFrame{ClientAgentRosterFrame: protoClientAgentRosterFrame(event)}})
	}
	if len(frames) == 0 {
		return true
	}
	for _, frame := range frames {
		select {
		case <-session.closed:
			return false
		case session.writer <- frame:
			pushed := frame.GetClientAgentRosterFrame()
			session.lastEpoch, session.afterSequence = pushed.Epoch, pushed.Sequence
		case <-ctx.Done():
			return false
		}
	}
	return true
}

func actorReplySessionKey(sessionID, generationID, principal string) string {
	return sessionID + "\x00" + generationID + "\x00" + principal
}

func (s *Service) registerActorReplySession(request *subagentsv1.Envelope, writer chan<- *subagentsv1.Envelope, closed <-chan struct{}) {
	if _, ok := authenticatedClientSource(request.CallerIdentity); !ok || request.SessionId == "" || request.GenerationId == "" || len(request.SessionCredential) == 0 {
		return
	}
	key := actorReplySessionKey(request.SessionId, request.GenerationId, request.CallerIdentity)
	s.actorReplyMu.Lock()
	existing := s.actorReplySessions[key]
	s.actorReplyMu.Unlock()
	if existing != nil && existing.writer == writer {
		s.flushActorReplies(existing)
		return
	}
	session := &actorReplySession{sessionID: request.SessionId, generationID: request.GenerationId, principal: request.CallerIdentity, credential: append([]byte(nil), request.SessionCredential...), writer: writer, closed: closed}
	ctx, cancel := context.WithTimeout(context.Background(), requestTimeout)
	defer cancel()
	if route, routeErr := s.authorizeAgent(ctx, &subagentsv1.Envelope{SessionId: session.sessionID, GenerationId: session.generationID, CallerIdentity: session.principal, SessionCredential: session.credential}, session.principal, []string{"observe", "send", "ask", "prompt"}); routeErr == nil && route.Allowed {
		if handle, handleErr := randomHandle(); handleErr == nil {
			if attached, attachErr := s.attachRequest(ctx, route.PID, &application.AttachAgent{SessionID: session.sessionID, GenerationID: route.GenerationID, Principal: route.Principal, AgentID: session.principal, RequestedCapabilities: []string{"observe", "send", "ask", "prompt"}, IssuedHandle: handle}); attachErr == nil && attached.Completed {
				session.selfHandle, session.selfFence = attached.Handle, attached.Fence
			}
		}
	}
	key = actorReplySessionKey(session.sessionID, session.generationID, session.principal)
	s.actorReplyMu.Lock()
	s.actorReplySessions[key] = session
	s.actorReplyMu.Unlock()
	s.flushActorReplies(session)
	s.flushRegularDeliveries(session, "regular client attached")
}

func (s *Service) unregisterActorReplySession(sessionID, generationID, principal string) {
	key := actorReplySessionKey(sessionID, generationID, principal)
	s.actorReplyMu.Lock()
	delete(s.actorReplySessions, key)
	s.actorReplyMu.Unlock()
}

func (s *Service) trackActorMessageCompletion(request *subagentsv1.Envelope, intent *application.BridgeIntent, completion <-chan application.BridgeIntentResult) {
	if request == nil || intent == nil || completion == nil || intent.Mode != application.BridgeMessageAsk {
		return
	}
	go func() {
		select {
		case result := <-completion:
			s.recordActorMessageReply(context.Background(), &application.ActorMessageReply{SessionID: request.SessionId, GenerationID: request.GenerationId, Principal: request.CallerIdentity, SourceAgentID: intent.SourceAgentID, TargetAgentID: intent.TargetAgentID, RequestID: intent.RequestID, DedupeID: intent.DedupeID, ChainID: intent.ChainID, SourceMutationSequence: intent.SourceMutationSequence, Mode: intent.Mode, Result: result})
		case <-time.After(max(time.Until(intent.Deadline), time.Millisecond)):
		}
	}()
}

func (s *Service) recordActorMessageReply(ctx context.Context, reply *application.ActorMessageReply) {
	if reply == nil || reply.SessionID == "" || reply.GenerationID == "" || reply.Principal == "" || reply.RequestID == "" || reply.DedupeID == "" || reply.ChainID == "" {
		return
	}
	result := reply.Result
	if len(result.Result) > maxPromptBytes {
		result.Result = result.Result[:maxPromptBytes]
	}
	if len(result.Reason) > 240 {
		result.Reason = result.Reason[:240]
	}
	key := actorReplySessionKey(reply.SessionID, reply.GenerationID, reply.Principal)
	frame := &subagentsv1.Envelope{ProtocolMajor: protocol.ProtocolMajor, ProtocolMinor: protocol.ProtocolMinor, SessionId: reply.SessionID, GenerationId: reply.GenerationID, RequestId: reply.RequestID, CallerIdentity: reply.Principal, Payload: &subagentsv1.Envelope_ActorMessageReplyFrame{ActorMessageReplyFrame: &subagentsv1.ActorMessageReplyFrame{OriginalRequestId: reply.RequestID, DedupeId: reply.DedupeID, ChainId: reply.ChainID, SourceMutationSequence: reply.SourceMutationSequence, Accepted: result.Accepted, Completed: result.Completed, BoundedResult: append([]byte(nil), result.Result...), Reason: result.Reason, Source: protoCommunicationPeer(s.communicationPeer(ctx, reply.SourceAgentID)), Target: protoCommunicationPeer(s.communicationPeer(ctx, reply.TargetAgentID)), Kind: actorMessageKind(subagentsv1.ActorMessageRequest_Mode(reply.Mode))}}}
	s.actorReplyMu.Lock()
	records := s.actorReplies[key]
	for index := range records {
		if records[index].frame.GetActorMessageReplyFrame().OriginalRequestId == reply.RequestID {
			records[index].frame = frame
			s.actorReplies[key] = records
			session := s.actorReplySessions[key]
			s.actorReplyMu.Unlock()
			if session != nil && !records[index].delivered {
				s.flushActorReplies(session)
			}
			return
		}
	}
	s.actorReplyNext[key]++
	frame.Sequence = s.actorReplyNext[key]
	records = append(records, actorReplyRecord{sequence: frame.Sequence, frame: frame})
	if len(records) > maxRequestResults {
		records = records[len(records)-maxRequestResults:]
	}
	s.actorReplies[key] = records
	session := s.actorReplySessions[key]
	s.actorReplyMu.Unlock()
	if session != nil {
		s.flushActorReplies(session)
	}
}

func (s *Service) flushActorReplyPrincipal(principal string) {
	s.actorReplyMu.Lock()
	sessions := make([]*actorReplySession, 0, len(s.actorReplySessions))
	for _, session := range s.actorReplySessions {
		if session.principal == principal {
			sessions = append(sessions, session)
		}
	}
	s.actorReplyMu.Unlock()
	for _, session := range sessions {
		s.flushActorReplies(session)
	}
}

func (s *Service) flushAllActorReplies() {
	s.actorReplyMu.Lock()
	sessions := make([]*actorReplySession, 0, len(s.actorReplySessions))
	for _, session := range s.actorReplySessions {
		sessions = append(sessions, session)
	}
	s.actorReplyMu.Unlock()
	for _, session := range sessions {
		s.flushActorReplies(session)
	}
}

func (s *Service) pushRegularDeliveryUpdate(agentID, reason string) {
	s.actorReplyMu.Lock()
	sessions := make([]*actorReplySession, 0, len(s.actorReplySessions))
	for _, session := range s.actorReplySessions {
		if session.principal == agentID {
			sessions = append(sessions, session)
		}
	}
	s.actorReplyMu.Unlock()
	for _, session := range sessions {
		s.flushRegularDeliveries(session, reason)
	}
}

func (s *Service) flushActorReplies(session *actorReplySession) bool {
	if session == nil {
		return false
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), requestTimeout)
	defer cancel()
	value, err := s.system.NoSender().Ask(ctx, s.sessionRegistry, &application.SessionAuthorization{SessionID: session.sessionID, GenerationID: session.generationID, Caller: session.principal, Credential: session.credential, Capability: "observe"}, requestTimeout)
	if err != nil {
		return false
	}
	result, ok := value.(*application.AuthorizationResult)
	if !ok || !result.Allowed {
		return false
	}
	route, err := s.authorizeAgent(ctx, &subagentsv1.Envelope{SessionId: session.sessionID, GenerationId: session.generationID, CallerIdentity: session.principal, SessionCredential: session.credential}, session.principal, []string{"observe"})
	if err != nil || !route.Allowed {
		return false
	}
	drained := make(chan []application.ActorTaskCompleted, 1)
	if err := s.system.NoSender().Tell(ctx, route.PID, &application.DrainReceivedTaskCompletions{Result: drained}); err != nil {
		return false
	}
	var completions []application.ActorTaskCompleted
	select {
	case completions = <-drained:
	case <-ctx.Done():
		return false
	}
	key := actorReplySessionKey(session.sessionID, session.generationID, session.principal)
	for _, completion := range completions {
		s.actorReplyMu.Lock()
		delivered := false
		for _, record := range s.actorReplies[key] {
			if record.frame.GetActorMessageReplyFrame().CompletionKey == completion.CompletionKey && record.delivered {
				delivered = true
				break
			}
		}
		if delivered {
			s.actorReplyMu.Unlock()
			continue
		}
		s.actorReplyNext[key]++
		frame := &subagentsv1.Envelope{ProtocolMajor: protocol.ProtocolMajor, ProtocolMinor: protocol.ProtocolMinor, SessionId: session.sessionID, GenerationId: session.generationID, RequestId: completion.OriginalRequestID, CallerIdentity: session.principal, Sequence: s.actorReplyNext[key], Payload: &subagentsv1.Envelope_ActorMessageReplyFrame{ActorMessageReplyFrame: &subagentsv1.ActorMessageReplyFrame{ThreadId: completion.ThreadID, CompletionKey: completion.CompletionKey, OriginalRequestId: completion.OriginalRequestID, DedupeId: completion.DedupeID, ChainId: completion.ChainID, SourceMutationSequence: completion.SourceMutationSequence, Accepted: completion.Terminal.Accepted, Completed: completion.Terminal.Completed, BoundedResult: append([]byte(nil), completion.Terminal.Result...), Reason: completion.Terminal.Reason, Source: protoCommunicationPeer(completion.Source), Target: protoCommunicationPeer(completion.Target), Kind: bridgeDeliveryKindLabel(completion.Kind)}}}
		s.actorReplyMu.Unlock()
		select {
		case <-session.closed:
			return false
		case session.writer <- frame:
		case <-ctx.Done():
			return false
		}
		s.actorReplyMu.Lock()
		s.actorReplies[key] = append(s.actorReplies[key], actorReplyRecord{sequence: frame.Sequence, frame: frame, delivered: true})
		s.actorReplyMu.Unlock()
	}
	return true
}

func (s *Service) flushRegularDeliveries(session *actorReplySession, reason string) bool {
	if session == nil || session.selfHandle == "" || session.selfFence == 0 {
		return false
	}
	session.mu.Lock()
	defer session.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), requestTimeout)
	defer cancel()
	route, err := s.authorizeAgent(ctx, &subagentsv1.Envelope{SessionId: session.sessionID, GenerationId: session.generationID, CallerIdentity: session.principal, SessionCredential: session.credential, AgentHandle: session.selfHandle, AgentFence: session.selfFence}, session.principal, []string{"observe"})
	if err != nil || !route.Allowed {
		return false
	}
	value, err := s.system.NoSender().Ask(ctx, route.PID, &application.PollBridge{SessionID: session.sessionID, GenerationID: route.GenerationID, Principal: route.Principal, Handle: session.selfHandle, Fence: session.selfFence, AfterSequence: session.afterSequence, MaxItems: 64}, requestTimeout)
	if err != nil {
		return false
	}
	poll, ok := value.(*application.BridgePollResult)
	if !ok {
		return false
	}
	deliveries := s.protoBridgeDeliveries(ctx, poll.Deliveries)
	if len(poll.Events) == 0 && len(deliveries) == 0 {
		return true
	}
	frame := &subagentsv1.Envelope{ProtocolMajor: protocol.ProtocolMajor, ProtocolMinor: protocol.ProtocolMinor, SessionId: session.sessionID, GenerationId: session.generationID, CallerIdentity: session.principal, AgentHandle: session.selfHandle, AgentFence: session.selfFence, Payload: &subagentsv1.Envelope_BridgePushFrame{BridgePushFrame: &subagentsv1.BridgePushFrame{AgentId: session.principal, Events: protoBridgeEvents(poll.Events), Deliveries: deliveries, LatestSequence: poll.LatestSequence, Reason: reason}}}
	select {
	case <-session.closed:
		return false
	case session.writer <- frame:
		session.afterSequence = poll.LatestSequence
		return true
	case <-ctx.Done():
		return false
	}
}

func (s *Service) bridgePushRegistration(request, response *subagentsv1.Envelope, writer chan<- *subagentsv1.Envelope, closed <-chan struct{}) *bridgePushSession {
	payload, ok := request.Payload.(*subagentsv1.Envelope_BridgeConnectRequest)
	if !ok || response.GetBridgeConnectResponse() == nil || !response.GetBridgeConnectResponse().Accepted {
		return nil
	}
	bridge := response.GetBridgeConnectResponse()
	return &bridgePushSession{sessionID: request.SessionId, generationID: request.GenerationId, principal: request.CallerIdentity, credential: append([]byte(nil), request.SessionCredential...), agentID: payload.BridgeConnectRequest.AgentId, handle: bridge.AgentHandle, fence: bridge.Fence, afterSequence: payload.BridgeConnectRequest.LastAckedSequence, writer: writer, closed: closed}
}

func (s *Service) registerBridgePush(session *bridgePushSession) {
	suffix, suffixErr := randomHandle()
	if suffixErr != nil {
		suffix = fmt.Sprint(time.Now().UnixNano())
	}
	pid, err := s.guardian.SpawnChild(context.Background(), "bridge-session-"+session.handle+"-"+suffix, newBridgeSessionActor(s, session), actor.WithMailbox(actor.NewNonBlockingBoundedMailbox(128)), actor.WithPassivationStrategy(passivation.NewLongLivedStrategy()))
	if err != nil || pid == nil {
		return
	}
	s.pushMu.Lock()
	s.pushSessions[session] = pid
	s.pushMu.Unlock()
	if s.bridgeWatcher != nil {
		_ = s.system.NoSender().Tell(context.Background(), s.bridgeWatcher, &watchBridgeSession{pid: pid})
	}
	if err := s.system.NoSender().Tell(context.Background(), pid, &application.BridgeSessionAgentUpdate{AgentID: session.agentID, Reason: "post-fence replay"}); err != nil {
		s.unregisterBridgePush(session)
	}
}

func (s *Service) unregisterBridgePush(session *bridgePushSession) {
	s.pushMu.Lock()
	pid := s.pushSessions[session]
	delete(s.pushSessions, session)
	s.pushMu.Unlock()
	if pid != nil {
		_ = s.system.NoSender().Tell(context.Background(), pid, &application.BridgeSessionClosed{Session: session})
		_ = pid.Shutdown(context.Background())
	}
}

func (s *Service) pushBridgeReplay(session *bridgePushSession, reason string) {
	s.pushMu.Lock()
	pid := s.pushSessions[session]
	s.pushMu.Unlock()
	if pid != nil {
		if err := s.system.NoSender().Tell(context.Background(), pid, &application.BridgeSessionAgentUpdate{AgentID: session.agentID, Reason: reason}); err != nil {
			s.unregisterBridgePush(session)
		}
	}
}

func (s *Service) removeDeadBridgePushPID(pid *actor.PID) {
	s.pushMu.Lock()
	defer s.pushMu.Unlock()
	for session, current := range s.pushSessions {
		if current == pid {
			delete(s.pushSessions, session)
		}
	}
}

func (s *Service) removeBridgeSessionActorName(name string) {
	s.pushMu.Lock()
	defer s.pushMu.Unlock()
	for session, current := range s.pushSessions {
		if current != nil && current.Name() == name {
			delete(s.pushSessions, session)
		}
	}
}

func (s *Service) pushBridgeUpdate(agentID, reason string) {
	s.pushMu.Lock()
	pids := make([]*actor.PID, 0, len(s.pushSessions))
	for session, pid := range s.pushSessions {
		if session.agentID == agentID && pid != nil {
			pids = append(pids, pid)
		}
	}
	s.pushMu.Unlock()
	for _, pid := range pids {
		if err := s.system.NoSender().Tell(context.Background(), pid, &application.BridgeSessionAgentUpdate{AgentID: agentID, Reason: reason}); err != nil {
			s.removeDeadBridgePushPID(pid)
		}
	}
}

func (s *Service) updateBridgeAckCursor(agentID, sessionID, generationID, handle string, fence, sequence uint64) {
	s.pushMu.Lock()
	defer s.pushMu.Unlock()
	for session := range s.pushSessions {
		if session.agentID == agentID && session.sessionID == sessionID && session.generationID == generationID && session.handle == handle && session.fence == fence && sequence > session.afterSequence {
			session.afterSequence = sequence
		}
	}
}

func (s *Service) pushBridgeToSession(session *bridgePushSession, reason string) bool {
	session.mu.Lock()
	defer session.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), requestTimeout)
	defer cancel()
	request := &subagentsv1.Envelope{ProtocolMajor: protocol.ProtocolMajor, DeadlineUnixMillis: time.Now().Add(requestTimeout).UnixMilli(), SessionId: session.sessionID, GenerationId: session.generationID, CallerIdentity: session.principal, SessionCredential: append([]byte(nil), session.credential...), AgentHandle: session.handle, AgentFence: session.fence}
	route, err := s.authorizeAgent(ctx, request, session.agentID, []string{"hosted_bridge"})
	if err != nil || !route.Allowed {
		return false
	}
	value, err := s.system.NoSender().Ask(ctx, route.PID, &application.PollBridge{SessionID: session.sessionID, GenerationID: route.GenerationID, Principal: route.Principal, Handle: session.handle, Fence: session.fence, AfterSequence: session.afterSequence, MaxItems: 64}, requestTimeout)
	if err != nil {
		return false
	}
	poll, ok := value.(*application.BridgePollResult)
	if !ok {
		return false
	}
	if len(poll.Events) == 0 && len(poll.Deliveries) == 0 {
		return true
	}
	deliveries := s.protoBridgeDeliveries(ctx, poll.Deliveries)
	frame := &subagentsv1.Envelope{ProtocolMajor: protocol.ProtocolMajor, ProtocolMinor: protocol.ProtocolMinor, Payload: &subagentsv1.Envelope_BridgePushFrame{BridgePushFrame: &subagentsv1.BridgePushFrame{AgentId: session.agentID, Events: protoBridgeEvents(poll.Events), Deliveries: deliveries, LatestSequence: poll.LatestSequence, Reason: reason}}}
	select {
	case <-session.closed:
		return false
	case session.writer <- frame:
		if len(deliveries) == 0 {
			session.afterSequence = poll.LatestSequence
		}
		return true
	case <-ctx.Done():
		return false
	}
}

func (s *Service) sequenceResponse(replay *connectionReplay, request *subagentsv1.Envelope) *subagentsv1.Envelope {
	if request.DeadlineUnixMillis <= 0 || time.Now().After(time.UnixMilli(request.DeadlineUnixMillis)) {
		return errorResponse(request, subagentsv1.ProtocolError_CODE_DEADLINE_EXCEEDED, "request deadline expired")
	}
	digest, err := envelopeDigest(request)
	if err != nil {
		return errorResponse(request, subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "request cannot be canonicalized")
	}
	if request.Sequence == 0 {
		return errorResponse(request, subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "sequence must be nonzero")
	}
	if request.Sequence <= replay.highest {
		record, exists := replay.entries[request.Sequence]
		if !exists {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "sequence replay is outside the bounded replay window")
		}
		if record.digest != digest {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "sequence payload collision")
		}
		if !s.reauthorizeReplay(request) {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_SESSION_MISMATCH, "session authorization is no longer valid")
		}
		return proto.Clone(record.response).(*subagentsv1.Envelope)
	}
	if request.Sequence-replay.highest > maxSequenceAdvance {
		return errorResponse(request, subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "sequence advance exceeds bound")
	}
	response := s.dispatch(request)
	replay.highest = request.Sequence
	replay.entries[request.Sequence] = sequenceRecord{digest: digest, response: proto.Clone(response).(*subagentsv1.Envelope)}
	replay.order = append(replay.order, request.Sequence)
	if len(replay.order) > maxConnectionReplay {
		delete(replay.entries, replay.order[0])
		replay.order = replay.order[1:]
	}
	return response
}

func (s *Service) reauthorizeReplay(request *subagentsv1.Envelope) bool {
	if _, ok := request.Payload.(*subagentsv1.Envelope_HealthRequest); ok {
		return true
	}
	if _, ok := request.Payload.(*subagentsv1.Envelope_HostedAdminRequest); ok {
		return s.authorizedAdmin(request.SessionCredential)
	}
	if bootstrap, ok := request.Payload.(*subagentsv1.Envelope_ClientSessionRequest); ok && bootstrap.ClientSessionRequest.Operation == subagentsv1.ClientSessionRequest_OPERATION_OPEN {
		return s.authorizedAdmin(request.SessionCredential)
	}
	capability := "observe"
	if attach, ok := request.Payload.(*subagentsv1.Envelope_AttachRequest); ok {
		route, err := s.authorizeAgent(context.Background(), request, attach.AttachRequest.AgentId, attach.AttachRequest.RequestedCapabilities)
		return err == nil && route.Allowed
	}
	var agentID string
	switch payload := request.Payload.(type) {
	case *subagentsv1.Envelope_ResolveAgentRequest:
		agentID = payload.ResolveAgentRequest.AgentId
	case *subagentsv1.Envelope_ReattachRequest:
		agentID = payload.ReattachRequest.AgentId
	case *subagentsv1.Envelope_DetachAgentRequest:
		agentID = payload.DetachAgentRequest.AgentId
	case *subagentsv1.Envelope_SubscribeAgentRequest:
		agentID = payload.SubscribeAgentRequest.AgentId
	case *subagentsv1.Envelope_UnsubscribeAgentRequest:
		agentID = payload.UnsubscribeAgentRequest.AgentId
	case *subagentsv1.Envelope_BridgeConnectRequest:
		agentID = payload.BridgeConnectRequest.AgentId
		capability = "hosted_bridge"
	case *subagentsv1.Envelope_BridgeReplaceRequest:
		agentID = payload.BridgeReplaceRequest.AgentId
		capability = "hosted_bridge"
	case *subagentsv1.Envelope_BridgeLifecycleRequest:
		agentID = payload.BridgeLifecycleRequest.AgentId
		capability = "hosted_bridge"
	case *subagentsv1.Envelope_BridgeHeartbeatRequest:
		agentID = payload.BridgeHeartbeatRequest.AgentId
		capability = "hosted_bridge"
	case *subagentsv1.Envelope_ActorMessageRequest:
		agentID = payload.ActorMessageRequest.Target
		var ok bool
		capability, ok = actorModeCapability(payload.ActorMessageRequest.Mode)
		if !ok {
			return false
		}
	case *subagentsv1.Envelope_PromptTaskRequest:
		agentID = payload.PromptTaskRequest.Target
		capability = "prompt"
	case *subagentsv1.Envelope_TaskLifecycleRequest:
		agentID = payload.TaskLifecycleRequest.Target
		capability = "prompt"
	case *subagentsv1.Envelope_ActorControlRequest:
		agentID = payload.ActorControlRequest.Target
		var ok bool
		capability, ok = actorControlCapability(payload.ActorControlRequest.Intent)
		if !ok {
			return false
		}
	case *subagentsv1.Envelope_BridgeDeliveryAckRequest:
		agentID = payload.BridgeDeliveryAckRequest.AgentId
		capability = "hosted_bridge"
		if source, ok := authenticatedClientSource(request.CallerIdentity); ok && source == agentID {
			capability = "observe"
		}
	case *subagentsv1.Envelope_BridgePollRequest:
		agentID = payload.BridgePollRequest.AgentId
		capability = "hosted_bridge"
	case *subagentsv1.Envelope_ClientAgentRosterRequest:
		capability = "observe"
	}
	if agentID != "" {
		route, err := s.authorizeAgent(context.Background(), request, agentID, []string{capability})
		return err == nil && route.Allowed
	}
	value, err := s.system.NoSender().Ask(context.Background(), s.sessionRegistry, &application.SessionAuthorization{SessionID: request.SessionId, GenerationID: request.GenerationId, Caller: request.CallerIdentity, Credential: request.SessionCredential, Capability: capability}, requestTimeout)
	if err != nil {
		return false
	}
	result, ok := value.(*application.AuthorizationResult)
	return ok && result.Allowed
}

func (s *Service) dispatch(request *subagentsv1.Envelope) *subagentsv1.Envelope {
	response := responseEnvelope(request)
	if request.DeadlineUnixMillis <= 0 || time.Now().After(time.UnixMilli(request.DeadlineUnixMillis)) {
		response.Payload = protocolError(subagentsv1.ProtocolError_CODE_DEADLINE_EXCEEDED, "request deadline expired")
		return response
	}
	ctx, cancel := context.WithDeadline(context.Background(), time.UnixMilli(request.DeadlineUnixMillis))
	defer cancel()
	if payload, ok := request.Payload.(*subagentsv1.Envelope_HostedAdminRequest); ok {
		return s.hostedAdminResponse(ctx, request, payload.HostedAdminRequest)
	}
	if payload, ok := request.Payload.(*subagentsv1.Envelope_ClientSessionRequest); ok {
		return s.clientSessionResponse(ctx, request, payload.ClientSessionRequest)
	}

	switch payload := request.Payload.(type) {
	case *subagentsv1.Envelope_HealthRequest:
		health, err := s.Health(ctx)
		if err != nil {
			return internalError(response)
		}
		response.Payload = &subagentsv1.Envelope_HealthResponse{HealthResponse: &subagentsv1.HealthResponse{Live: health.Live, Ready: health.Ready, Status: health.Status}}
	case *subagentsv1.Envelope_ClientAgentRosterRequest:
		message := &application.ClientAgentRosterSnapshot{SessionID: request.SessionId, GenerationID: request.GenerationId, Caller: request.CallerIdentity, Credential: request.SessionCredential, LastEpoch: payload.ClientAgentRosterRequest.LastEpoch, AfterSequence: payload.ClientAgentRosterRequest.AfterSequence}
		value, err := s.system.NoSender().Ask(ctx, s.agentRegistry, message, requestTimeout)
		if err != nil {
			return internalError(response)
		}
		snapshot, ok := value.(*application.ClientAgentRosterSnapshotResult)
		if !ok {
			return internalError(response)
		}
		if snapshot.Reason != "" {
			response.Payload = &subagentsv1.Envelope_AgentOperationResponse{AgentOperationResponse: &subagentsv1.AgentOperationResponse{Completed: false, Reason: snapshot.Reason}}
			return response
		}
		response.Payload = &subagentsv1.Envelope_AgentOperationResponse{AgentOperationResponse: &subagentsv1.AgentOperationResponse{Completed: true}}
	case *subagentsv1.Envelope_ListAgentsRequest:
		message := &application.ListAgents{SessionID: request.SessionId, GenerationID: request.GenerationId, Caller: request.CallerIdentity, Credential: request.SessionCredential}
		value, err := s.system.NoSender().Ask(ctx, s.agentRegistry, message, requestTimeout)
		if err != nil {
			return internalError(response)
		}
		list, ok := value.(*application.AgentList)
		if !ok {
			return internalError(response)
		}
		agents := make([]*subagentsv1.AgentReference, 0, len(list.Agents))
		for _, item := range list.Agents {
			agents = append(agents, protoPublicAgentReference(item))
		}
		if s.publicDirectory != nil {
			remote, err := s.system.NoSender().Ask(ctx, s.publicDirectory, message, requestTimeout)
			if err == nil {
				if publicList, ok := remote.(*application.AgentList); ok {
					for _, item := range publicList.Agents {
						agents = append(agents, protoPublicAgentReference(item))
					}
				}
			}
		}
		response.Payload = &subagentsv1.Envelope_ListAgentsResponse{ListAgentsResponse: &subagentsv1.ListAgentsResponse{Agents: agents}}
	case *subagentsv1.Envelope_ResolveAgentRequest:
		message := &application.ResolveAgent{SessionID: request.SessionId, GenerationID: request.GenerationId, Caller: request.CallerIdentity, Credential: request.SessionCredential, AgentID: payload.ResolveAgentRequest.AgentId}
		value, err := s.system.NoSender().Ask(ctx, s.agentRegistry, message, requestTimeout)
		if err != nil {
			return internalError(response)
		}
		resolved, ok := value.(*application.ResolveAgentResult)
		if !ok {
			return internalError(response)
		}
		if !resolved.Found && s.publicDirectory != nil {
			remote, err := s.system.NoSender().Ask(ctx, s.publicDirectory, &application.LookupPublicAgent{SessionID: request.SessionId, GenerationID: request.GenerationId, Caller: request.CallerIdentity, Credential: request.SessionCredential, AgentID: payload.ResolveAgentRequest.AgentId}, requestTimeout)
			if err == nil {
				if found, ok := remote.(*application.PublicAgentLookupResult); ok && found.Found {
					response.Payload = &subagentsv1.Envelope_ResolveAgentResponse{ResolveAgentResponse: &subagentsv1.ResolveAgentResponse{Agent: protoPublicAgentReference(found.Record.Reference)}}
					return response
				}
			}
		}
		if !resolved.Found {
			candidates := make([]*subagentsv1.AgentReference, 0, len(resolved.Candidates))
			for _, candidate := range resolved.Candidates {
				candidates = append(candidates, protoPublicAgentReference(candidate))
			}
			if len(candidates) == 0 {
				response.Payload = protocolError(subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "agent not found or access denied")
				return response
			}
			response.Payload = &subagentsv1.Envelope_ResolveAgentResponse{ResolveAgentResponse: &subagentsv1.ResolveAgentResponse{Candidates: candidates, Ambiguous: resolved.Ambiguous}}
			return response
		}
		response.Payload = &subagentsv1.Envelope_ResolveAgentResponse{ResolveAgentResponse: &subagentsv1.ResolveAgentResponse{Agent: protoPublicAgentReference(resolved.Agent)}}
	case *subagentsv1.Envelope_AttachRequest:
		route, err := s.authorizeAgent(ctx, request, payload.AttachRequest.AgentId, payload.AttachRequest.RequestedCapabilities)
		if err != nil || !route.Allowed {
			response.Payload = rejectedAttach("agent or session authorization denied")
			return response
		}
		return s.deduplicatedMutation(request, response, route, "attach", func() *subagentsv1.Envelope {
			handle, err := randomHandle()
			if err != nil {
				return internalError(response)
			}
			message := &application.AttachAgent{SessionID: request.SessionId, GenerationID: route.GenerationID, Principal: route.Principal, AgentID: payload.AttachRequest.AgentId, RequestedCapabilities: payload.AttachRequest.RequestedCapabilities, IssuedHandle: handle}
			return s.attachResponse(ctx, response, route.PID, message)
		})
	case *subagentsv1.Envelope_ReattachRequest:
		route, err := s.authorizeAgent(ctx, request, payload.ReattachRequest.AgentId, []string{"observe"})
		if err != nil || !route.Allowed {
			response.Payload = rejectedAttach("agent or session authorization denied")
			return response
		}
		return s.deduplicatedMutation(request, response, route, "reattach", func() *subagentsv1.Envelope {
			handle, err := randomHandle()
			if err != nil {
				return internalError(response)
			}
			message := &application.ReattachAgent{SessionID: request.SessionId, GenerationID: route.GenerationID, Principal: route.Principal, AgentID: payload.ReattachRequest.AgentId, PreviousHandle: request.AgentHandle, PreviousFence: payload.ReattachRequest.PreviousFence, IssuedHandle: handle}
			return s.attachResponse(ctx, response, route.PID, message)
		})
	case *subagentsv1.Envelope_DetachAgentRequest:
		route, err := s.authorizeAgent(ctx, request, payload.DetachAgentRequest.AgentId, []string{"observe"})
		if err != nil || !route.Allowed {
			response.Payload = protocolError(subagentsv1.ProtocolError_CODE_SESSION_MISMATCH, "agent or session authorization denied")
			return response
		}
		message := &application.DetachAgent{SessionID: request.SessionId, GenerationID: route.GenerationID, Principal: route.Principal, AgentID: payload.DetachAgentRequest.AgentId, Handle: request.AgentHandle, Fence: request.AgentFence}
		return s.operationResponse(ctx, response, route.PID, message)
	case *subagentsv1.Envelope_SubscribeAgentRequest:
		route, err := s.authorizeAgent(ctx, request, payload.SubscribeAgentRequest.AgentId, []string{"observe"})
		if err != nil || !route.Allowed {
			response.Payload = protocolError(subagentsv1.ProtocolError_CODE_SESSION_MISMATCH, "agent or session authorization denied")
			return response
		}
		result := make(chan application.OperationResult, 1)
		message := &application.SubscribeAgent{SessionID: request.SessionId, GenerationID: route.GenerationID, Principal: route.Principal, AgentID: payload.SubscribeAgentRequest.AgentId, Handle: request.AgentHandle, Fence: request.AgentFence, AfterRevision: payload.SubscribeAgentRequest.AfterRevision, Result: result}
		if err := s.system.NoSender().Tell(ctx, route.PID, message); err != nil {
			return internalError(response)
		}
		select {
		case operation := <-result:
			response.Payload = &subagentsv1.Envelope_AgentOperationResponse{AgentOperationResponse: &subagentsv1.AgentOperationResponse{Completed: operation.Completed, Revision: operation.Revision, Reason: operation.Reason}}
			return response
		case <-ctx.Done():
			return internalError(response)
		}
	case *subagentsv1.Envelope_UnsubscribeAgentRequest:
		route, err := s.authorizeAgent(ctx, request, payload.UnsubscribeAgentRequest.AgentId, []string{"observe"})
		if err != nil || !route.Allowed {
			response.Payload = protocolError(subagentsv1.ProtocolError_CODE_SESSION_MISMATCH, "agent or session authorization denied")
			return response
		}
		result := make(chan application.OperationResult, 1)
		message := &application.UnsubscribeAgent{SessionID: request.SessionId, GenerationID: route.GenerationID, Principal: route.Principal, AgentID: payload.UnsubscribeAgentRequest.AgentId, Handle: request.AgentHandle, Fence: request.AgentFence, Result: result}
		if err := s.system.NoSender().Tell(ctx, route.PID, message); err != nil {
			return internalError(response)
		}
		select {
		case operation := <-result:
			response.Payload = &subagentsv1.Envelope_AgentOperationResponse{AgentOperationResponse: &subagentsv1.AgentOperationResponse{Completed: operation.Completed, Revision: operation.Revision, Reason: operation.Reason}}
		case <-ctx.Done():
			return errorResponse(request, subagentsv1.ProtocolError_CODE_DEADLINE_EXCEEDED, "unsubscribe deadline expired")
		}
	case *subagentsv1.Envelope_BridgeConnectRequest:
		route, err := s.authorizeAgent(ctx, request, payload.BridgeConnectRequest.AgentId, []string{"hosted_bridge", "observe"})
		if err != nil || !route.Allowed {
			s.hostedMu.Lock()
			s.hostedStartupFailure[payload.BridgeConnectRequest.AgentId] = "hosted bridge authorization denied"
			s.hostedMu.Unlock()
			response.Payload = &subagentsv1.Envelope_BridgeConnectResponse{BridgeConnectResponse: &subagentsv1.BridgeConnectResponse{Reason: "hosted bridge authorization denied"}}
			return response
		}
		connect := &application.BridgeConnect{SessionID: request.SessionId, GenerationID: route.GenerationID, Principal: route.Principal, AgentID: payload.BridgeConnectRequest.AgentId, RuntimeID: payload.BridgeConnectRequest.RuntimeId, Incarnation: payload.BridgeConnectRequest.Incarnation, PiSessionID: payload.BridgeConnectRequest.PiSessionId}
		result, err := s.bridgeRequest(ctx, route.PID, connect)
		if err != nil {
			return internalError(response)
		}
		if result.NeedsAttach {
			handle, err := randomHandle()
			if err != nil {
				return internalError(response)
			}
			attached, err := s.attachRequest(ctx, route.PID, &application.AttachAgent{SessionID: request.SessionId, GenerationID: route.GenerationID, Principal: route.Principal, AgentID: payload.BridgeConnectRequest.AgentId, RequestedCapabilities: []string{"hosted_bridge", "observe", "send", "ask", "control_abort", "control_shutdown"}, IssuedHandle: handle})
			if err != nil || !attached.Completed {
				return internalError(response)
			}
			connect.Handle, connect.Fence = attached.Handle, attached.Fence
			result, err = s.bridgeRequest(ctx, route.PID, connect)
			if err != nil {
				return internalError(response)
			}
		}
		if !result.Accepted {
			reason := hostedStartupFailureClass(result.Reason)
			s.hostedMu.Lock()
			s.hostedStartupFailure[payload.BridgeConnectRequest.AgentId] = reason
			s.hostedMu.Unlock()
			fmt.Fprintln(os.Stderr, "hosted bridge connect rejected:", reason)
		}
		response.Payload = &subagentsv1.Envelope_BridgeConnectResponse{BridgeConnectResponse: &subagentsv1.BridgeConnectResponse{Accepted: result.Accepted, AgentHandle: result.Handle, Fence: result.Fence, Reason: result.Reason, ActorMessageHighWater: result.ActorMessageHighWater}}
	case *subagentsv1.Envelope_BridgeReplaceRequest:
		route, err := s.authorizeAgent(ctx, request, payload.BridgeReplaceRequest.AgentId, []string{"hosted_bridge", "observe"})
		if err != nil || !route.Allowed {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_SESSION_MISMATCH, "hosted bridge replacement authorization denied")
		}
		newHandle, err := randomHandle()
		if err != nil {
			return internalError(response)
		}
		result, err := s.bridgeRequest(ctx, route.PID, &application.BridgeReplace{SessionID: request.SessionId, GenerationID: route.GenerationID, Principal: route.Principal, AgentID: payload.BridgeReplaceRequest.AgentId, Handle: request.AgentHandle, Fence: request.AgentFence, RuntimeID: payload.BridgeReplaceRequest.RuntimeId, Incarnation: payload.BridgeReplaceRequest.Incarnation, PreviousPiSessionID: payload.BridgeReplaceRequest.PreviousPiSessionId, NewPiSessionID: payload.BridgeReplaceRequest.NewPiSessionId, NewHandle: newHandle})
		if err != nil {
			return internalError(response)
		}
		response.Payload = &subagentsv1.Envelope_BridgeConnectResponse{BridgeConnectResponse: &subagentsv1.BridgeConnectResponse{Accepted: result.Accepted, AgentHandle: result.Handle, Fence: result.Fence, Reason: result.Reason, ActorMessageHighWater: result.ActorMessageHighWater}}
	case *subagentsv1.Envelope_BridgeLifecycleRequest:
		route, err := s.authorizeAgent(ctx, request, payload.BridgeLifecycleRequest.AgentId, []string{"hosted_bridge"})
		if err != nil || !route.Allowed {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_SESSION_MISMATCH, "hosted bridge authorization denied")
		}
		event, validEvent := bridgeLifecycleEvent(payload.BridgeLifecycleRequest.Event)
		if !validEvent {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "hosted bridge lifecycle event is unknown")
		}
		result, err := s.bridgeRequest(ctx, route.PID, &application.BridgeLifecycle{SessionID: request.SessionId, GenerationID: route.GenerationID, Principal: route.Principal, AgentID: payload.BridgeLifecycleRequest.AgentId, Handle: request.AgentHandle, Fence: request.AgentFence, RuntimeID: payload.BridgeLifecycleRequest.RuntimeId, Incarnation: payload.BridgeLifecycleRequest.Incarnation, Event: event})
		if err != nil {
			return internalError(response)
		}
		if result.Accepted {
			s.pushBridgeUpdate(payload.BridgeLifecycleRequest.AgentId, "bridge lifecycle")
		} else {
			fmt.Fprintln(os.Stderr, "hosted bridge lifecycle rejected:", hostedStartupFailureClass(result.Reason))
		}
		response.Payload = &subagentsv1.Envelope_BridgeLifecycleResponse{BridgeLifecycleResponse: &subagentsv1.BridgeLifecycleResponse{Accepted: result.Accepted, Reason: result.Reason}}
	case *subagentsv1.Envelope_BridgeHeartbeatRequest:
		route, err := s.authorizeAgent(ctx, request, payload.BridgeHeartbeatRequest.AgentId, []string{"hosted_bridge"})
		if err != nil || !route.Allowed {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_SESSION_MISMATCH, "hosted bridge heartbeat authorization denied")
		}
		result, err := s.bridgeRequest(ctx, route.PID, &application.BridgeHeartbeat{SessionID: request.SessionId, GenerationID: route.GenerationID, Principal: route.Principal, AgentID: payload.BridgeHeartbeatRequest.AgentId, Handle: request.AgentHandle, Fence: request.AgentFence, RuntimeID: payload.BridgeHeartbeatRequest.RuntimeId, Incarnation: payload.BridgeHeartbeatRequest.Incarnation})
		if err != nil {
			return internalError(response)
		}
		if !result.Accepted {
			fmt.Fprintln(os.Stderr, "hosted bridge heartbeat rejected:", hostedStartupFailureClass(result.Reason))
		}
		response.Payload = &subagentsv1.Envelope_BridgeHeartbeatResponse{BridgeHeartbeatResponse: &subagentsv1.BridgeHeartbeatResponse{Accepted: result.Accepted, Reason: result.Reason}}
	case *subagentsv1.Envelope_TaskLifecycleRequest:
		return s.taskLifecycleResponse(ctx, request, payload.TaskLifecycleRequest)
	case *subagentsv1.Envelope_PromptTaskRequest:
		// PromptTask was the synchronous predecessor to ActorMessage Ask and
		// delivered BridgeIntent directly. Retain wire compatibility but reject
		// the bypass before routing or model effects.
		return errorResponse(request, subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "prompt task retired; use actor message ask")
	case *subagentsv1.Envelope_ActorMessageRequest:
		capability, validMode := actorModeCapability(payload.ActorMessageRequest.Mode)
		source, validSource := authenticatedHostedSource(request.CallerIdentity)
		if !validSource {
			source, validSource = authenticatedClientSource(request.CallerIdentity)
		}
		if !validMode || !validSource {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "actor message mode or authenticated source is invalid")
		}
		targetRoute, err := s.authorizeAgent(ctx, request, payload.ActorMessageRequest.Target, []string{capability})
		if err != nil || !targetRoute.Allowed {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_SESSION_MISMATCH, "actor message authorization denied")
		}
		if _, isClient := authenticatedClientSource(request.CallerIdentity); isClient {
			if err := s.ensureTerminalAgent(ctx, source); err != nil {
				return internalError(response)
			}
		}
		sourceRoute, err := s.authorizeAgent(ctx, request, source, []string{capability})
		if err != nil || !sourceRoute.Allowed {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_SESSION_MISMATCH, "source actor authorization denied")
		}
		receipt := make(chan application.BridgeIntentResult, 1)
		// The envelope deadline bounds this transport request only. Durable actor
		// work has an independent bounded lifetime so a hosted bridge's short RPC
		// timeout cannot expire an admitted task before target credit/persistence.
		task := &application.SendActorTask{TargetPID: targetRoute.PID, TargetPeer: s.communicationPeer(ctx, payload.ActorMessageRequest.Target), RequestID: request.RequestId, RequiredCapability: capability, DedupeID: payload.ActorMessageRequest.DedupeId, ChainID: payload.ActorMessageRequest.ChainId, Deadline: durableActorTaskDeadline(time.Now()), HopLimit: payload.ActorMessageRequest.HopLimit, SourceMutationSequence: payload.ActorMessageRequest.SourceMutationSequence, Mode: application.BridgeMessageMode(payload.ActorMessageRequest.Mode), Payload: append([]byte(nil), payload.ActorMessageRequest.BoundedPayload...), Receipt: receipt}
		// Local and remote targets follow the same source-actor credit/task
		// protocol: the resolved target PID addresses the concrete agent actor
		// (possibly on another node) and the actor plane preserves the source
		// ActorRef as sender across remoting.
		targetPID, targetAvailable := s.resolveRemoteAgentActor(ctx, targetRoute, payload.ActorMessageRequest.Target)
		if !targetAvailable {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_SESSION_MISMATCH, "actor message target actor unavailable")
		}
		task.TargetPID = targetPID
		var result *application.BridgeIntentResult
		if err := s.system.NoSender().Tell(ctx, sourceRoute.PID, task); err != nil {
			return internalError(response)
		}
		select {
		case completed := <-receipt:
			result = &completed
		case <-ctx.Done():
			return errorResponse(request, subagentsv1.ProtocolError_CODE_DEADLINE_EXCEEDED, "durable actor mutation deadline expired")
		}
		if result.Accepted {
			// Hosted admission may enqueue synchronously. Regular delivery is
			// pushed only by TargetTaskCommitted after the target durable commit.
			s.pushBridgeUpdate(payload.ActorMessageRequest.Target, "actor delivery admitted")
		}
		response.Payload = &subagentsv1.Envelope_ActorMessageResponse{ActorMessageResponse: &subagentsv1.ActorMessageResponse{Accepted: result.Accepted, Completed: result.Completed, BoundedResult: result.Result, Reason: result.Reason, Source: protoCommunicationPeer(s.communicationPeer(ctx, source)), Target: protoCommunicationPeer(s.communicationPeer(ctx, payload.ActorMessageRequest.Target)), Kind: actorMessageKind(payload.ActorMessageRequest.Mode)}}
	case *subagentsv1.Envelope_ActorControlRequest:
		capability, validIntent := actorControlCapability(payload.ActorControlRequest.Intent)
		source, validSource := authenticatedHostedSource(request.CallerIdentity)
		if !validSource {
			source, validSource = authenticatedClientSource(request.CallerIdentity)
		}
		if !validIntent || !validSource {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "actor control intent or authenticated source is invalid")
		}
		route, err := s.authorizeAgent(ctx, request, payload.ActorControlRequest.Target, []string{capability})
		if err != nil || !route.Allowed {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_SESSION_MISMATCH, "actor control authorization denied")
		}
		completion := make(chan application.BridgeIntentResult, 1)
		control := &application.BridgeControl{SessionID: request.SessionId, GenerationID: route.GenerationID, Principal: route.Principal, Handle: request.AgentHandle, Fence: request.AgentFence, SourceAgentID: source, TargetAgentID: payload.ActorControlRequest.Target, RequestID: request.RequestId, DedupeID: payload.ActorControlRequest.DedupeId, ChainID: payload.ActorControlRequest.ChainId, Deadline: time.UnixMilli(request.DeadlineUnixMillis), HopLimit: payload.ActorControlRequest.HopLimit, SourceMutationSequence: payload.ActorControlRequest.SourceMutationSequence, Intent: application.BridgeControlIntent(payload.ActorControlRequest.Intent), Completion: completion}
		if err := s.system.NoSender().Tell(ctx, route.PID, control); err != nil {
			return internalError(response)
		}
		var result *application.BridgeIntentResult
		select {
		case completed := <-completion:
			result = &completed
		case <-ctx.Done():
			return errorResponse(request, subagentsv1.ProtocolError_CODE_DEADLINE_EXCEEDED, "durable actor control deadline expired")
		}
		if result.Accepted {
			s.pushBridgeUpdate(payload.ActorControlRequest.Target, "actor control admitted")
		}
		response.Payload = &subagentsv1.Envelope_ActorMessageResponse{ActorMessageResponse: &subagentsv1.ActorMessageResponse{Accepted: result.Accepted, Completed: result.Completed, Reason: result.Reason, Source: protoCommunicationPeer(s.communicationPeer(ctx, source)), Target: protoCommunicationPeer(s.communicationPeer(ctx, payload.ActorControlRequest.Target)), Kind: actorControlKind(payload.ActorControlRequest.Intent)}}
	case *subagentsv1.Envelope_BridgeDeliveryAckRequest:
		capability := "hosted_bridge"
		if source, ok := authenticatedClientSource(request.CallerIdentity); ok && source == payload.BridgeDeliveryAckRequest.AgentId {
			capability = "observe"
		}
		route, err := s.authorizeAgent(ctx, request, payload.BridgeDeliveryAckRequest.AgentId, []string{capability})
		if err != nil || !route.Allowed {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_SESSION_MISMATCH, "delivery acknowledgement authorization denied")
		}
		completion := make(chan application.BridgeDeliveryAckResult, 1)
		ack := &application.BridgeDeliveryAck{SessionID: request.SessionId, GenerationID: route.GenerationID, Principal: route.Principal, Handle: request.AgentHandle, Fence: request.AgentFence, Sequence: payload.BridgeDeliveryAckRequest.Sequence, DedupeID: payload.BridgeDeliveryAckRequest.DedupeId, Delivered: payload.BridgeDeliveryAckRequest.Delivered, Reason: payload.BridgeDeliveryAckRequest.Reason, Result: append([]byte(nil), payload.BridgeDeliveryAckRequest.BoundedResult...), RuntimeID: payload.BridgeDeliveryAckRequest.RuntimeId, Incarnation: payload.BridgeDeliveryAckRequest.Incarnation, PiSessionID: payload.BridgeDeliveryAckRequest.PiSessionId, Kind: payload.BridgeDeliveryAckRequest.Kind, SourceScope: payload.BridgeDeliveryAckRequest.SourceScope, CompletionKey: payload.BridgeDeliveryAckRequest.CompletionKey, ThreadID: payload.BridgeDeliveryAckRequest.ThreadId, SchedulerEpoch: payload.BridgeDeliveryAckRequest.SchedulerEpoch, ActiveLease: payload.BridgeDeliveryAckRequest.ActiveLease, ThreadTurn: payload.BridgeDeliveryAckRequest.ThreadTurn, BridgeRunCounter: payload.BridgeDeliveryAckRequest.BridgeRunCounter, AgentEndObserved: payload.BridgeDeliveryAckRequest.AgentEndObserved, AgentSettledObserved: payload.BridgeDeliveryAckRequest.AgentSettledObserved, Completion: completion}
		if err := s.system.NoSender().Tell(ctx, route.PID, ack); err != nil {
			return internalError(response)
		}
		var result *application.BridgeDeliveryAckResult
		select {
		case completed := <-completion:
			result = &completed
		case <-ctx.Done():
			return errorResponse(request, subagentsv1.ProtocolError_CODE_DEADLINE_EXCEEDED, "durable delivery acknowledgement deadline expired")
		}
		if result.Accepted {
			s.updateBridgeAckCursor(payload.BridgeDeliveryAckRequest.AgentId, request.SessionId, request.GenerationId, request.AgentHandle, request.AgentFence, result.Cursor)
			s.pushRegularDeliveryUpdate(payload.BridgeDeliveryAckRequest.AgentId, "delivery acknowledgement accepted")
		} else {
			// Every acknowledgement rejection is logged with a bounded reason so a
			// stalled acknowledgement chain is diagnosable from the daemon side
			// instead of surfacing only as a silent cursor gap.
			fmt.Fprintf(os.Stderr, "bridge delivery ack rejected: agent=%s sequence=%d dedupe=%s reason=%s\n", boundedLogAtom(payload.BridgeDeliveryAckRequest.AgentId, 64), payload.BridgeDeliveryAckRequest.Sequence, boundedLogAtom(payload.BridgeDeliveryAckRequest.DedupeId, 64), boundedLogAtom(result.Reason, 120))
		}
		response.Payload = &subagentsv1.Envelope_BridgeDeliveryAckResponse{BridgeDeliveryAckResponse: &subagentsv1.BridgeDeliveryAckResponse{Accepted: result.Accepted, Reason: result.Reason, Cursor: result.Cursor}}
	case *subagentsv1.Envelope_BridgePollRequest:
		agentID := payload.BridgePollRequest.AgentId
		route, err := s.authorizeAgent(ctx, request, agentID, []string{"hosted_bridge"})
		if err != nil || !route.Allowed {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_SESSION_MISMATCH, "hosted bridge authorization denied")
		}
		value, err := s.system.NoSender().Ask(ctx, route.PID, &application.PollBridge{SessionID: request.SessionId, GenerationID: route.GenerationID, Principal: route.Principal, Handle: request.AgentHandle, Fence: request.AgentFence, AfterSequence: payload.BridgePollRequest.AfterSequence, MaxItems: payload.BridgePollRequest.MaxItems}, requestTimeout)
		if err != nil {
			return internalError(response)
		}
		poll, ok := value.(*application.BridgePollResult)
		if !ok {
			return internalError(response)
		}
		response.Payload = &subagentsv1.Envelope_BridgePollResponse{BridgePollResponse: &subagentsv1.BridgePollResponse{Events: protoBridgeEvents(poll.Events), Deliveries: s.protoBridgeDeliveries(ctx, poll.Deliveries), LatestSequence: poll.LatestSequence, More: poll.More}}
	default:
		response.Payload = protocolError(subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "operation is not implemented in milestone 1")
	}
	return response
}

func protoBridgeEvents(events []application.BridgeEvent) []*subagentsv1.BridgeEvent {
	result := make([]*subagentsv1.BridgeEvent, 0, len(events))
	for _, event := range events {
		result = append(result, &subagentsv1.BridgeEvent{Sequence: event.Sequence, AgentId: event.AgentID, Revision: event.Revision, Operation: event.Operation})
	}
	return result
}

// protoBridgeDeliveries is the single shared conversion every bridge
// delivery-serializing surface funnels through: initial push, poll, and the
// reconnect/post-fence replay paths all serialize deliveries exclusively here.
// Acknowledgement identity is required: a delivery without it can never be
// acknowledged, so it must never reach a bridge client, and withholding it is
// logged loudly instead of being dropped silently.
func (s *Service) protoBridgeDeliveries(ctx context.Context, deliveries []application.BridgeDelivery) []*subagentsv1.BridgeDelivery {
	result := make([]*subagentsv1.BridgeDelivery, 0, len(deliveries))
	for _, delivery := range deliveries {
		// Defense in depth: a delivery without acknowledgement identity can
		// never be acknowledged, so it must never reach a bridge client.
		if !delivery.AckIdentityComplete() {
			fmt.Fprintf(os.Stderr, "bridge delivery withheld: agent=%s sequence=%d kind=%d dedupe=%s reason=acknowledgement identity incomplete\n", boundedLogAtom(delivery.TargetAgentID, 64), delivery.Sequence, delivery.Kind, boundedLogAtom(delivery.DedupeID, 64))
			continue
		}
		source, target := delivery.Source, delivery.Target
		if source.StableID == "" {
			source = s.communicationPeer(ctx, delivery.SourceAgentID)
		}
		if target.StableID == "" {
			target = s.communicationPeer(ctx, delivery.TargetAgentID)
		}
		result = append(result, &subagentsv1.BridgeDelivery{Sequence: delivery.Sequence, SourceAgentId: delivery.SourceAgentID, TargetAgentId: delivery.TargetAgentID, RequestId: delivery.RequestID, DeadlineUnixMillis: delivery.Deadline.UnixMilli(), DedupeId: delivery.DedupeID, HopLimit: delivery.HopLimit, BoundedPayload: delivery.Payload, Policy: subagentsv1.BridgeDelivery_Policy(delivery.Policy), Kind: subagentsv1.BridgeDelivery_Kind(delivery.Kind), ChainId: delivery.ChainID, Source: protoCommunicationPeer(source), Target: protoCommunicationPeer(target), SourceScope: delivery.SourceScope, CompletionKey: delivery.CompletionKey, ThreadId: delivery.ThreadID, SchedulerEpoch: delivery.SchedulerEpoch, ActiveLease: delivery.ActiveLease, ThreadTurn: delivery.ThreadTurn})
	}
	return result
}

func protoCommunicationPeer(peer application.CommunicationPeer) *subagentsv1.CommunicationPeer {
	return &subagentsv1.CommunicationPeer{StableId: peer.StableID, DisplayName: peer.DisplayName, Role: peer.Role}
}

func (s *Service) communicationPeer(ctx context.Context, stableID string) application.CommunicationPeer {
	value, err := s.system.NoSender().Ask(ctx, s.agentRegistry, &application.ResolveAgentControl{AgentID: stableID}, min(requestTimeout, boundedRemaining(ctx, requestTimeout)))
	if err == nil {
		if resolved, ok := value.(*application.AgentControlPID); ok && resolved.Found {
			return application.CommunicationPeer{StableID: resolved.Reference.AgentID, DisplayName: resolved.Reference.DisplayName, Role: resolved.Reference.Role}
		}
	}
	return application.CommunicationPeer{StableID: stableID, DisplayName: neutralPeerDisplay(stableID), Role: ""}
}

func (s *Service) deduplicatedMutation(request, response *subagentsv1.Envelope, route *application.AgentRoute, operation string, execute func() *subagentsv1.Envelope) *subagentsv1.Envelope {
	if request.RequestId == "" {
		return errorResponse(request, subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "request_id is required")
	}
	digest, err := payloadDigest(request)
	if err != nil {
		return internalError(response)
	}
	key := route.Principal + "\x00" + request.SessionId + "\x00" + route.GenerationID + "\x00" + operation + "\x00" + request.RequestId
	s.requestMu.Lock()
	defer s.requestMu.Unlock()
	if record, exists := s.requestResults[key]; exists {
		if record.digest != digest {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "request id payload collision")
		}
		if record.response == nil {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "request identity is outside the retained result window")
		}
		return proto.Clone(record.response).(*subagentsv1.Envelope)
	}
	if len(s.requestResults) >= maxRequestIdentities {
		return errorResponse(request, subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "request identity ledger is full")
	}
	result := execute()
	s.requestResults[key] = requestRecord{digest: digest, response: proto.Clone(result).(*subagentsv1.Envelope)}
	s.requestOrder = append(s.requestOrder, key)
	if len(s.requestOrder) > maxRequestResults {
		evicted := s.requestOrder[0]
		record := s.requestResults[evicted]
		record.response = nil
		s.requestResults[evicted] = record
		s.requestOrder = s.requestOrder[1:]
	}
	return result
}

func (s *Service) authorizeAgent(ctx context.Context, request *subagentsv1.Envelope, agentID string, capabilities []string) (*application.AgentRoute, error) {
	value, err := s.system.NoSender().Ask(ctx, s.agentRegistry, &application.AuthorizeAgentAccess{SessionID: request.SessionId, GenerationID: request.GenerationId, Caller: request.CallerIdentity, Credential: request.SessionCredential, AgentID: agentID, Capabilities: capabilities}, requestTimeout)
	if err != nil {
		return nil, err
	}
	route, ok := value.(*application.AgentRoute)
	if !ok {
		return nil, errors.New("unexpected agent authorization response")
	}
	if route.Allowed || s.publicDirectory == nil {
		return route, nil
	}
	remote, err := s.system.NoSender().Ask(ctx, s.publicDirectory, &application.RoutePublicAgent{SessionID: request.SessionId, GenerationID: request.GenerationId, Caller: request.CallerIdentity, Credential: request.SessionCredential, AgentID: agentID, Capabilities: capabilities}, requestTimeout)
	if err != nil {
		return nil, err
	}
	publicRoute, ok := remote.(*application.PublicAgentRouteResult)
	if !ok || !publicRoute.Allowed {
		return route, nil
	}
	pid, err := s.system.NoSender().RemoteLookup(ctx, publicRoute.Record.Host, publicRoute.Record.Port, publicRoute.Record.ActorName)
	if err != nil || pid == nil {
		return route, nil
	}
	return &application.AgentRoute{Allowed: true, PID: pid, GenerationID: request.GenerationId, Principal: request.CallerIdentity}, nil
}

// resolveRemoteAgentActor resolves a remote agent route to its concrete agent
// actor through the remote node's placement authority, so cross-node messages
// address the agent actor itself and the source ActorRef survives as sender.
// Failures are deterministic and never leak host or port details.
func (s *Service) resolveRemoteAgentActor(ctx context.Context, route *application.AgentRoute, agentID string) (*actor.PID, bool) {
	if !route.PID.IsRemote() {
		return route.PID, true
	}
	path := route.PID.Path()
	if path == nil {
		return nil, false
	}
	reply, err := s.system.NoSender().Ask(ctx, route.PID, &application.ResolveAgentActor{AgentID: agentID}, requestTimeout)
	if err != nil {
		return nil, false
	}
	actorRef, ok := reply.(*application.AgentActorRef)
	if !ok || !actorRef.Found || actorRef.ActorName == "" {
		return nil, false
	}
	pid, err := s.system.NoSender().RemoteLookup(ctx, path.Host(), path.Port(), actorRef.ActorName)
	if err != nil || pid == nil {
		return nil, false
	}
	return pid, true
}

func (s *Service) attachRequest(ctx context.Context, pid *actor.PID, message any) (*application.AttachResult, error) {
	results := make(chan application.AttachResult, 1)
	switch value := message.(type) {
	case *application.AttachAgent:
		if pid.IsRemote() {
			reply, err := s.system.NoSender().Ask(ctx, pid, &application.RemoteAttachAgent{SessionID: value.SessionID, GenerationID: value.GenerationID, Principal: value.Principal, AgentID: value.AgentID, RequestedCapabilities: value.RequestedCapabilities, IssuedHandle: value.IssuedHandle}, requestTimeout)
			if err != nil {
				return nil, err
			}
			result, ok := reply.(*application.AttachResult)
			if !ok {
				return nil, errors.New("unexpected remote attach response")
			}
			return result, nil
		}
		value.Result = results
	case *application.ReattachAgent:
		value.Result = results
	default:
		return nil, errors.New("unsupported attach request")
	}
	if err := s.system.NoSender().Tell(ctx, pid, message); err != nil {
		return nil, err
	}
	select {
	case result := <-results:
		return &result, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}
func (s *Service) bridgeRequest(ctx context.Context, pid *actor.PID, message any) (*application.BridgeResult, error) {
	results := make(chan application.BridgeResult, 1)
	switch value := message.(type) {
	case *application.BridgeConnect:
		value.Result = results
	case *application.BridgeReplace:
		value.Result = results
	case *application.BridgeLifecycle:
		value.Result = results
	case *application.BridgeHeartbeat:
		value.Result = results
	default:
		return nil, errors.New("unsupported bridge request")
	}
	if err := s.system.NoSender().Tell(ctx, pid, message); err != nil {
		return nil, err
	}
	select {
	case result := <-results:
		return &result, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (s *Service) attachResponse(ctx context.Context, response *subagentsv1.Envelope, pid *actor.PID, message any) *subagentsv1.Envelope {
	results := make(chan application.AttachResult, 1)
	var result *application.AttachResult
	switch value := message.(type) {
	case *application.AttachAgent:
		if pid.IsRemote() {
			reply, err := s.system.NoSender().Ask(ctx, pid, &application.RemoteAttachAgent{SessionID: value.SessionID, GenerationID: value.GenerationID, Principal: value.Principal, AgentID: value.AgentID, RequestedCapabilities: value.RequestedCapabilities, IssuedHandle: value.IssuedHandle}, requestTimeout)
			if err != nil {
				return internalError(response)
			}
			var ok bool
			result, ok = reply.(*application.AttachResult)
			if !ok {
				return internalError(response)
			}
			goto done
		}
		value.Result = results
	case *application.ReattachAgent:
		value.Result = results
	default:
		return internalError(response)
	}
	if err := s.system.NoSender().Tell(ctx, pid, message); err != nil {
		return internalError(response)
	}
	select {
	case value := <-results:
		result = &value
	case <-ctx.Done():
		return internalError(response)
	}
done:
	status := subagentsv1.AttachResponse_STATUS_COMPLETED
	if !result.Completed {
		status = subagentsv1.AttachResponse_STATUS_REJECTED
	}
	response.Payload = &subagentsv1.Envelope_AttachResponse{AttachResponse: &subagentsv1.AttachResponse{Status: status, AgentHandle: result.Handle, Fence: result.Fence, Reason: result.Reason}}
	return response
}

func (s *Service) operationResponse(ctx context.Context, response *subagentsv1.Envelope, pid *actor.PID, message any) *subagentsv1.Envelope {
	results := make(chan application.OperationResult, 1)
	detach, ok := message.(*application.DetachAgent)
	if !ok {
		return internalError(response)
	}
	detach.Result = results
	if err := s.system.NoSender().Tell(ctx, pid, message); err != nil {
		return internalError(response)
	}
	var result *application.OperationResult
	select {
	case value := <-results:
		result = &value
	case <-ctx.Done():
		return internalError(response)
	}
	response.Payload = &subagentsv1.Envelope_AgentOperationResponse{AgentOperationResponse: &subagentsv1.AgentOperationResponse{Completed: result.Completed, Revision: result.Revision, Reason: result.Reason}}
	return response
}

func protoClientAgentRosterFrame(event application.ClientAgentRosterEvent) *subagentsv1.ClientAgentRosterFrame {
	operation := subagentsv1.ClientAgentRosterFrame_OPERATION_STATUS
	switch event.Operation {
	case application.ClientAgentRosterSnapshotReset:
		operation = subagentsv1.ClientAgentRosterFrame_OPERATION_SNAPSHOT_RESET
	case application.ClientAgentRosterUpsert:
		operation = subagentsv1.ClientAgentRosterFrame_OPERATION_UPSERT
	case application.ClientAgentRosterRemove:
		operation = subagentsv1.ClientAgentRosterFrame_OPERATION_REMOVE
	}
	agentID := event.AgentID
	if agentID == "" {
		agentID = event.Reference.AgentID
	}
	return &subagentsv1.ClientAgentRosterFrame{Operation: operation, Epoch: event.Epoch, Sequence: event.Sequence, AgentId: agentID, Agent: protoPublicAgentReference(event.Reference), Status: event.Status}
}

func protoPublicAgentReference(item application.AgentReference) *subagentsv1.AgentReference {
	binding := item.AuthorityBinding
	return &subagentsv1.AgentReference{AgentId: item.AgentID, LifecycleRevision: item.LifecycleRevision, Role: item.Role, DisplayName: item.DisplayName, RetentionPolicy: item.RetentionPolicy, RecoveryPolicy: item.RecoveryPolicy,
		AuthorityBinding: &subagentsv1.PhaseOneAuthorityBinding{Kind: subagentsv1.PhaseOneAuthorityBinding_Kind(binding.Kind)},
		HostedPiRuntime:  &subagentsv1.HostedPiRuntimeBinding{State: subagentsv1.HostedPiRuntimeBinding_State(item.HostedPiRuntime.State), BridgeReady: item.HostedPiRuntime.BridgeReady, CleanupPending: item.HostedPiRuntime.CleanupPending, AggregateId: item.AgentID, DisplayName: item.DisplayName, Role: item.Role},
	}
}

func protoAgentReference(item application.AgentReference) *subagentsv1.AgentReference {
	binding, hosted := item.AuthorityBinding, item.HostedPiRuntime
	return &subagentsv1.AgentReference{AgentId: item.AgentID, LifecycleRevision: item.LifecycleRevision, Role: item.Role, DisplayName: item.DisplayName, RetentionPolicy: item.RetentionPolicy, RecoveryPolicy: item.RecoveryPolicy,
		AuthorityBinding: &subagentsv1.PhaseOneAuthorityBinding{Kind: subagentsv1.PhaseOneAuthorityBinding_Kind(binding.Kind), ObservedUpstreamRunId: binding.ObservedUpstreamRunID, HostedRuntimeId: binding.HostedRuntimeID},
		HostedPiRuntime:  &subagentsv1.HostedPiRuntimeBinding{State: subagentsv1.HostedPiRuntimeBinding_State(hosted.State), Lifetime: subagentsv1.HostedPiRuntimeBinding_Lifetime(hosted.Lifetime), TmuxOwnership: subagentsv1.HostedPiRuntimeBinding_TmuxOwnership(hosted.TmuxOwnership), ControlBoundary: subagentsv1.HostedPiRuntimeBinding_ControlBoundary(hosted.ControlBoundary), VisualizationBoundary: subagentsv1.HostedPiRuntimeBinding_VisualizationBoundary(hosted.VisualizationBoundary), RuntimeId: hosted.RuntimeID, Incarnation: hosted.Incarnation, TmuxSession: hosted.TmuxSession, TmuxWindow: hosted.TmuxWindow, TmuxPane: hosted.TmuxPane, TmuxSessionId: hosted.TmuxSessionID, TmuxWindowId: hosted.TmuxWindowID, TmuxServerPid: hosted.TmuxServerPID, TmuxServerStartToken: hosted.TmuxServerStartToken, OwnershipIndeterminate: hosted.OwnershipIndeterminate, CleanupPending: hosted.CleanupPending, PanePid: hosted.PanePID, ProcessStartToken: hosted.ProcessStartToken, Tty: hosted.TTY, PiSessionDirectory: hosted.PiSessionDirectory, PiSessionName: hosted.PiSessionName, BridgeReady: hosted.BridgeReady, AggregateId: item.AgentID, DisplayName: item.DisplayName, Role: item.Role},
	}
}

func payloadDigest(request *subagentsv1.Envelope) ([32]byte, error) {
	canonical := proto.Clone(request).(*subagentsv1.Envelope)
	canonical.ProtocolMajor = 0
	canonical.ProtocolMinor = 0
	canonical.SessionId = ""
	canonical.GenerationId = ""
	canonical.RequestId = ""
	canonical.DeadlineUnixMillis = 0
	canonical.Sequence = 0
	canonical.CallerIdentity = ""
	canonical.SessionCredential = nil
	return envelopeDigest(canonical)
}
func envelopeDigest(request *subagentsv1.Envelope) ([32]byte, error) {
	encoded, err := (proto.MarshalOptions{Deterministic: true}).Marshal(request)
	if err != nil {
		return [32]byte{}, err
	}
	return sha256.Sum256(encoded), nil
}
func responseEnvelope(request *subagentsv1.Envelope) *subagentsv1.Envelope {
	return &subagentsv1.Envelope{ProtocolMajor: protocol.ProtocolMajor, ProtocolMinor: protocol.ProtocolMinor, SessionId: request.SessionId, GenerationId: request.GenerationId, RequestId: request.RequestId, Sequence: request.Sequence}
}
func protocolError(code subagentsv1.ProtocolError_Code, message string) *subagentsv1.Envelope_ProtocolError {
	return &subagentsv1.Envelope_ProtocolError{ProtocolError: &subagentsv1.ProtocolError{Code: code, Message: message}}
}
func errorResponse(request *subagentsv1.Envelope, code subagentsv1.ProtocolError_Code, message string) *subagentsv1.Envelope {
	response := responseEnvelope(request)
	response.Payload = protocolError(code, message)
	return response
}
func internalError(response *subagentsv1.Envelope) *subagentsv1.Envelope {
	response.Payload = protocolError(subagentsv1.ProtocolError_CODE_INTERNAL, "internal service error")
	return response
}
func rejectedAttach(reason string) *subagentsv1.Envelope_AttachResponse {
	return &subagentsv1.Envelope_AttachResponse{AttachResponse: &subagentsv1.AttachResponse{Status: subagentsv1.AttachResponse_STATUS_REJECTED, Reason: reason}}
}
func validateHostedAdminConfig(config HostedAdminConfig) error {
	if !config.Enabled {
		return nil
	}
	for name, value := range map[string]string{"tmux_binary": config.TmuxBinary, "pi_binary": config.PiBinary, "bridge_extension": config.BridgeExtension, "state_directory": config.StateDirectory, "pi_session_directory": config.PiSessionDirectory, "credential_directory": config.CredentialDirectory, "admin_credential_file": config.AdminCredentialFile, "default_project_directory": config.DefaultProjectDirectory} {
		if value == "" || value != strings.TrimSpace(value) || !filepath.IsAbs(value) {
			return fmt.Errorf("hosted admin %s must be an absolute trim-equal path", name)
		}
	}
	if config.TmuxConfig != "" && !filepath.IsAbs(config.TmuxConfig) {
		return errors.New("hosted admin tmux_config must be absolute when set")
	}
	return nil
}

func (s *Service) beginHostedOperation(parent context.Context) (context.Context, func(), error) {
	s.hostedOperationMu.Lock()
	defer s.hostedOperationMu.Unlock()
	if s.stopping.Load() {
		return nil, nil, errors.New("service shutdown rejects hosted operation")
	}
	if s.hostedOperationCount == 0 {
		s.hostedOperationDone = make(chan struct{})
	}
	s.hostedOperationCount++
	s.hostedOperationNext++
	id := s.hostedOperationNext
	ctx, cancel := context.WithCancel(parent)
	s.hostedOperationCancels[id] = cancel
	finish := func() {
		cancel()
		s.hostedOperationMu.Lock()
		delete(s.hostedOperationCancels, id)
		s.hostedOperationCount--
		if s.hostedOperationCount == 0 && s.hostedOperationDone != nil {
			close(s.hostedOperationDone)
			s.hostedOperationDone = nil
		}
		s.hostedOperationMu.Unlock()
	}
	return ctx, finish, nil
}

func (s *Service) hostedAgentLock(agentID string) *sync.Mutex {
	s.hostedOperationMu.Lock()
	defer s.hostedOperationMu.Unlock()
	lock := s.hostedAgentLocks[agentID]
	if lock == nil {
		lock = new(sync.Mutex)
		s.hostedAgentLocks[agentID] = lock
	}
	return lock
}

func durableActorTaskDeadline(now time.Time) time.Time { return now.Add(actorTaskDeliveryLifetime) }

func (s *Service) authorizedAdmin(credential []byte) bool {
	return s.hostedAdmin.Enabled && len(s.adminCredential) == 32 && len(credential) == 32 && subtle.ConstantTimeCompare(s.adminCredential, credential) == 1
}

func (s *Service) clientSessionResponse(ctx context.Context, request *subagentsv1.Envelope, command *subagentsv1.ClientSessionRequest) *subagentsv1.Envelope {
	response := responseEnvelope(request)
	if command == nil {
		return errorResponse(request, subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "client session operation is missing")
	}
	switch command.Operation {
	case subagentsv1.ClientSessionRequest_OPERATION_OPEN:
		if !s.authorizedAdmin(request.SessionCredential) {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_SESSION_MISMATCH, "client bootstrap authentication denied")
		}
		// A stable terminal identity reattaches the one durable terminal
		// AgentActor for that identity across reconnects and daemon restarts:
		// the session principal must not churn per OPEN or retained completions
		// strand in orphaned agent mailboxes nothing drains. Empty keeps the
		// legacy ephemeral mint for older clients.
		if command.TerminalIdentity != "" && !terminalIdentityPattern.MatchString(command.TerminalIdentity) {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "client terminal identity is invalid")
		}
		displayName, validDisplay := terminalMetadata(command.DisplayName, 80)
		role, validRole := terminalMetadata(command.Role, 64)
		if !validDisplay || !validRole {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "client terminal metadata is invalid")
		}
		random, err := randomHandle()
		if err != nil {
			return internalError(response)
		}
		caller := "client:" + random
		if command.TerminalIdentity != "" {
			caller = "client:" + command.TerminalIdentity
		}
		var actorMessageHighWater uint64
		if command.TerminalIdentity != "" {
			if err := s.ensureTerminalAgent(ctx, caller, displayName, role); err != nil {
				return internalError(response)
			}
			var err error
			actorMessageHighWater, err = s.terminalActorMessageHighWater(ctx, caller)
			if err != nil {
				return internalError(response)
			}
		}
		credential := make([]byte, 32)
		if _, err := rand.Read(credential); err != nil {
			return internalError(response)
		}
		expires := time.Now().Add(clientSessionTTL)
		session := application.OpenSession{SessionID: "client-session-" + random, GenerationID: "client-generation-" + random, Caller: caller, Credential: credential, Capabilities: []string{"observe", "send", "ask", "prompt", "control_abort", "control_shutdown"}, ExpiresAt: expires}
		if err := s.OpenSession(ctx, session); err != nil {
			response.Payload = &subagentsv1.Envelope_ClientSessionResponse{ClientSessionResponse: &subagentsv1.ClientSessionResponse{Reason: redactedLifecycleReason("client open", err)}}
			return response
		}
		clientPID, err := s.guardian.SpawnChild(ctx, session.SessionID, actors.NewClientSessionActor(session.SessionID, session.GenerationID, session.Caller), actor.WithMailbox(actor.NewNonBlockingBoundedMailbox(64)), actor.WithPassivationStrategy(passivation.NewLongLivedStrategy()))
		if err != nil {
			_ = s.CloseSession(ctx, session.SessionID)
			return internalError(response)
		}
		s.clientSessionMu.Lock()
		s.clientSessions[session.SessionID] = clientPID
		s.clientSessionMu.Unlock()
		response.Payload = &subagentsv1.Envelope_ClientSessionResponse{ClientSessionResponse: &subagentsv1.ClientSessionResponse{Accepted: true, SessionId: session.SessionID, GenerationId: session.GenerationID, CallerIdentity: session.Caller, SessionCredential: append([]byte(nil), credential...), ExpiresUnixMillis: expires.UnixMilli(), ActorMessageHighWater: actorMessageHighWater}}
		return response
	case subagentsv1.ClientSessionRequest_OPERATION_CLOSE:
		value, err := s.system.NoSender().Ask(ctx, s.sessionRegistry, &application.SessionAuthorization{SessionID: request.SessionId, GenerationID: request.GenerationId, Caller: request.CallerIdentity, Credential: request.SessionCredential, Capability: "observe"}, requestTimeout)
		authorized, ok := value.(*application.AuthorizationResult)
		if err != nil || !ok || !authorized.Allowed {
			return errorResponse(request, subagentsv1.ProtocolError_CODE_SESSION_MISMATCH, "client session close authorization denied")
		}
		if err := s.CloseSession(ctx, request.SessionId); err != nil {
			response.Payload = &subagentsv1.Envelope_ClientSessionResponse{ClientSessionResponse: &subagentsv1.ClientSessionResponse{Reason: redactedLifecycleReason("client close", err)}}
			return response
		}
		s.clientSessionMu.Lock()
		clientPID := s.clientSessions[request.SessionId]
		delete(s.clientSessions, request.SessionId)
		s.clientSessionMu.Unlock()
		if clientPID != nil {
			_ = clientPID.Shutdown(context.Background())
		}
		response.Payload = &subagentsv1.Envelope_ClientSessionResponse{ClientSessionResponse: &subagentsv1.ClientSessionResponse{Accepted: true}}
		return response
	default:
		return errorResponse(request, subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "client session operation is invalid")
	}
}

func (s *Service) taskLifecycleResponse(_ context.Context, request *subagentsv1.Envelope, _ *subagentsv1.TaskLifecycleRequest) *subagentsv1.Envelope {
	// The legacy lifecycle endpoint kept completion authority in a disposable
	// service map and delivered BridgeIntent directly, bypassing ActorTask
	// credit, durable thread identity, settlement, and introspection. Keep the
	// additive wire shape decodable but fail every operation closed; all
	// model-bearing work must use ActorMessage Ask -> ActorTask -> thread.
	return errorResponse(request, subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "task lifecycle retired; use actor message ask")
}

func (s *Service) hostedAdminResponse(ctx context.Context, request *subagentsv1.Envelope, command *subagentsv1.HostedAdminRequest) *subagentsv1.Envelope {
	response := responseEnvelope(request)
	if !s.authorizedAdmin(request.SessionCredential) {
		response.Payload = protocolError(subagentsv1.ProtocolError_CODE_SESSION_MISMATCH, "hosted admin authentication denied")
		return response
	}
	if command == nil || !validAgentID(command.AgentId) {
		response.Payload = protocolError(subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "hosted admin agent_id is invalid")
		return response
	}
	if command.TargetNode != "" && (s.actorPlane == nil || command.TargetNode != s.actorPlane.NodeIdentity) {
		return s.remoteHostedAdminResponse(ctx, request, command)
	}
	operationCtx, finish, err := s.beginHostedOperation(ctx)
	if err != nil {
		response.Payload = protocolError(subagentsv1.ProtocolError_CODE_INVALID_REQUEST, err.Error())
		return response
	}
	defer finish()
	lock := s.hostedAgentLock(command.AgentId)
	lock.Lock()
	defer lock.Unlock()
	ctx = operationCtx
	var binding application.HostedPiRuntimeBinding
	switch command.Operation {
	case subagentsv1.HostedAdminRequest_OPERATION_START:
		binding, err = s.startHostedAgent(ctx, command)
	case subagentsv1.HostedAdminRequest_OPERATION_STATUS:
		binding, err = s.hostedStatus(ctx, command.AgentId)
	case subagentsv1.HostedAdminRequest_OPERATION_STOP:
		binding, err = s.stopHostedAgent(ctx, command.AgentId)
	default:
		response.Payload = protocolError(subagentsv1.ProtocolError_CODE_INVALID_REQUEST, "hosted admin operation is invalid")
		return response
	}
	if err != nil {
		response.Payload = &subagentsv1.Envelope_HostedAdminResponse{HostedAdminResponse: &subagentsv1.HostedAdminResponse{AgentId: command.AgentId, Reason: err.Error()}}
		return response
	}
	attach := binding.TmuxSessionID
	if attach == "" {
		attach = binding.TmuxSession
	}
	response.Payload = &subagentsv1.Envelope_HostedAdminResponse{HostedAdminResponse: &subagentsv1.HostedAdminResponse{Accepted: true, AgentId: command.AgentId, Runtime: protoAgentReference(application.AgentReference{HostedPiRuntime: binding}).HostedPiRuntime, AttachTarget: attach}}
	return response
}

func (s *Service) startHostedAgent(ctx context.Context, command *subagentsv1.HostedAdminRequest) (application.HostedPiRuntimeBinding, error) {
	s.hostedMu.Lock()
	s.hostedStarting[command.AgentId]++
	s.hostedMu.Unlock()
	defer func() {
		s.hostedMu.Lock()
		s.hostedStarting[command.AgentId]--
		if s.hostedStarting[command.AgentId] == 0 {
			delete(s.hostedStarting, command.AgentId)
		}
		s.hostedMu.Unlock()
	}()
	return s.startHostedAgentOnce(ctx, command)
}

func (s *Service) startHostedAgentOnce(ctx context.Context, command *subagentsv1.HostedAdminRequest) (application.HostedPiRuntimeBinding, error) {
	s.hostedMu.Lock()
	if degraded, exists := s.hostedIndeterminate[command.AgentId]; exists {
		s.hostedMu.Unlock()
		return degraded, application.ErrHostedOwnershipIndeterminate
	}
	var registrationID string
	var registrationPlaceholder *registrationPlaceholder
	var registrationCleanup *registrationCleanup
	for _, candidate := range s.registrationPlaceholders {
		if candidate.agentID == command.AgentId {
			registrationPlaceholder = candidate
			break
		}
	}
	for id, candidate := range s.registrationCleanups {
		if candidate.agentID == command.AgentId {
			registrationID, registrationCleanup = id, candidate
			break
		}
	}
	s.hostedMu.Unlock()
	if registrationPlaceholder != nil {
		select {
		case <-registrationPlaceholder.done:
			return s.startHostedAgent(ctx, command)
		case <-ctx.Done():
			return application.HostedPiRuntimeBinding{}, ctx.Err()
		}
	}
	if registrationCleanup != nil {
		if err := s.attemptRegistrationCleanup(ctx, registrationID, registrationCleanup); err != nil {
			return application.HostedPiRuntimeBinding{}, fmt.Errorf("retry ambiguous registration cleanup: %w", err)
		}
	}
	s.hostedMu.Lock()
	_, cleanupPending := s.hostedCleanup[command.AgentId]
	s.hostedMu.Unlock()
	if cleanupPending {
		if err := s.cleanupHostedMetadata(ctx, command.AgentId); err != nil {
			return application.HostedPiRuntimeBinding{}, fmt.Errorf("retry prior hosted cleanup: %w", err)
		}
		s.hostedMu.Lock()
		delete(s.hostedTerminal, command.AgentId)
		s.hostedMu.Unlock()
	}
	project := command.ProjectDirectory
	if project == "" {
		project = s.hostedAdmin.DefaultProjectDirectory
	}
	if err := validateProjectDirectory(project); err != nil {
		return application.HostedPiRuntimeBinding{}, err
	}
	s.hostedMu.Lock()
	if owner := s.hostedProjects[project]; owner != "" && owner != command.AgentId {
		s.hostedMu.Unlock()
		return application.HostedPiRuntimeBinding{}, fmt.Errorf("project worktree is already owned by actor %s", owner)
	}
	s.hostedProjects[project] = command.AgentId
	s.hostedMu.Unlock()
	projectPublished := false
	defer func() {
		if projectPublished {
			return
		}
		s.hostedMu.Lock()
		if s.hostedProjects[project] == command.AgentId {
			delete(s.hostedProjects, project)
		}
		s.hostedMu.Unlock()
	}()
	random, err := randomHandle()
	if err != nil {
		return application.HostedPiRuntimeBinding{}, err
	}
	digest := sha256.Sum256([]byte(command.AgentId))
	suffix := fmt.Sprintf("%x", digest[:6])
	runtimeID, sessionID, generationID := "hosted-"+random, "hosted-session-"+random, "hosted-generation-"+random
	credential := make([]byte, 32)
	if _, err := rand.Read(credential); err != nil {
		return application.HostedPiRuntimeBinding{}, err
	}
	credentialFile := filepath.Join(s.hostedAdmin.CredentialDirectory, suffix+".json")
	if err := hostedpi.WriteCredentialFile(credentialFile, credential, true); err != nil {
		return application.HostedPiRuntimeBinding{}, fmt.Errorf("bootstrap hosted session credential: %w", err)
	}
	rollback := func() { _ = hostedpi.RemoveCredentialFile(credentialFile) }
	session := application.OpenSession{SessionID: sessionID, GenerationID: generationID, Caller: "hosted:" + command.AgentId, Credential: credential, Capabilities: []string{"observe", "hosted_bridge", "send", "ask", "prompt", "control_abort", "control_shutdown"}, Persistent: true}
	if err := s.OpenSession(ctx, session); err != nil {
		rollback()
		return application.HostedPiRuntimeBinding{}, err
	}
	spec := application.HostedPiLaunchSpec{AgentID: command.AgentId, RuntimeID: runtimeID, Incarnation: 1, TmuxSession: "ws-pi-" + suffix, TmuxWindow: "pi", PiSessionDirectory: filepath.Join(s.hostedAdmin.PiSessionDirectory, suffix), PiSessionName: "hosted-" + suffix}
	runtimeConfig := hostedpi.Config{TmuxBinary: s.hostedAdmin.TmuxBinary, PiBinary: s.hostedAdmin.PiBinary, BridgeExtension: s.hostedAdmin.BridgeExtension, DaemonEndpoint: hostedActorEndpoint(s.hostedAdmin), CredentialFile: credentialFile, ServerName: s.hostedAdmin.ServerName, TmuxConfig: s.hostedAdmin.TmuxConfig, ProjectDirectory: project, StateDirectory: s.hostedAdmin.StateDirectory, SessionID: sessionID, GenerationID: generationID, CallerIdentity: session.Caller, TrustProject: command.TrustProject && s.hostedAdmin.TrustProject}
	var runtime application.HostedPiRuntime = &hostedpi.Runtime{Config: runtimeConfig}
	if s.hostedAdmin.RuntimeFactory != nil {
		runtime = s.hostedAdmin.RuntimeFactory(runtimeConfig)
	}
	inactive := application.InactiveHostedPiRuntimeBinding()
	inactive.State, inactive.RuntimeID, inactive.Incarnation = application.HostedPiRuntimeStarting, runtimeID, 1
	inactive.DisplayName = command.DisplayName
	inactive.Role = command.Role
	durable := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, OwnerUID: os.Getuid(), AgentID: command.AgentId, AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: runtimeID}, AllowedCapabilities: append([]string(nil), session.Capabilities...), Retention: "explicit", Recovery: "owned-binding-v2", Session: application.DurableHostedSession{SessionID: sessionID, GenerationID: generationID, Caller: session.Caller, Capabilities: append([]string(nil), session.Capabilities...), ExpiresAt: session.ExpiresAt, Persistent: session.Persistent, CredentialFile: credentialFile}, LaunchSpec: spec, RuntimeConfig: application.DurableRuntimeConfig{ProjectDirectory: project, TrustProject: runtimeConfig.TrustProject}, Binding: inactive}
	if err := s.durableStore.Save(ctx, durable); err != nil {
		_ = s.CloseSession(context.Background(), sessionID)
		rollback()
		return application.HostedPiRuntimeBinding{}, fmt.Errorf("persist hosted registration before launch: %w", err)
	}
	registration := application.RegisterAgent{AgentID: command.AgentId, Role: command.Role, DisplayName: command.DisplayName, AuthorityBinding: durable.AuthorityBinding, HostedPiRuntime: inactive, AllowedCapability: append([]string(nil), session.Capabilities...), PhaseTwoOwned: true, Retention: durable.Retention, Recovery: durable.Recovery, Runtime: runtime, LaunchSpec: spec, RuntimeStartTimeout: 10 * time.Second, PersistencePID: s.persistencePID, IntrospectionRunner: s.introspectionRunner, DurableRecord: &durable}
	metadata := hostedRegistration{sessionID: sessionID, credentialFile: credentialFile}
	registerCtx, registerCancel := context.WithTimeout(context.Background(), requestTimeout)
	result, registerErr := s.registerAgent(registerCtx, registration, metadata)
	registerCancel()
	if registerErr != nil {
		if result != nil && result.CleanupPending {
			inactive.CleanupPending = true
			return inactive, registerErr
		}
		_ = s.CloseSession(context.Background(), sessionID)
		rollback()
		_ = s.durableStore.Remove(context.Background(), command.AgentId)
		return application.HostedPiRuntimeBinding{}, registerErr
	}
	s.hostedMu.Lock()
	if s.stopping.Load() {
		s.hostedMu.Unlock()
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = s.rollbackHostedRegistration(cleanupCtx, command.AgentId, result.RuntimePID, metadata)
		return application.HostedPiRuntimeBinding{}, errors.New("service shutdown rejected hosted publication")
	}
	s.hostedRuntimes[command.AgentId] = result.AgentPID
	s.hostedRegistrations[command.AgentId] = metadata
	projectPublished = true
	delete(s.hostedTerminal, command.AgentId)
	delete(s.hostedStartupFailure, command.AgentId)
	s.hostedMu.Unlock()
	for {
		binding, err := s.hostedStatus(ctx, command.AgentId)
		if err != nil {
			if ctx.Err() != nil {
				s.finishTimedOutHostedStart(command.AgentId, result.AgentPID, result.RuntimePID, metadata)
			}
			return binding, err
		}
		if binding.State == application.HostedPiRuntimeDegraded {
			if binding.OwnershipIndeterminate {
				return binding, errors.New("hosted runtime start degraded with indeterminate ownership")
			}
			cleanupCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if err := s.rollbackHostedRegistration(cleanupCtx, command.AgentId, result.AgentPID, metadata); err != nil {
				return binding, fmt.Errorf("rollback definitive hosted start failure: %w", err)
			}
			s.hostedMu.Lock()
			failure := s.hostedStartupFailure[command.AgentId]
			delete(s.hostedStartupFailure, command.AgentId)
			s.hostedMu.Unlock()
			if failure != "" {
				return binding, fmt.Errorf("hosted runtime start failed and was rolled back: %s", failure)
			}
			return binding, errors.New("hosted runtime start failed and was rolled back")
		}
		if binding.TmuxSessionID != "" {
			barrier, barrierErr := s.durableBarrier(ctx, result.AgentPID)
			if barrierErr != nil {
				return binding, fmt.Errorf("durable hosted publication barrier: %w", barrierErr)
			}
			if !barrier.Completed {
				return binding, fmt.Errorf("durable hosted publication barrier failed: %s", barrier.Reason)
			}
			return binding, nil
		}
		select {
		case <-ctx.Done():
			s.finishTimedOutHostedStart(command.AgentId, result.AgentPID, result.RuntimePID, metadata)
			return binding, ctx.Err()
		case <-time.After(10 * time.Millisecond):
		}
	}
}

func (s *Service) finishTimedOutHostedStart(agentID string, agentPID, runtimePID *actor.PID, metadata hostedRegistration) {
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		for {
			binding, err := s.hostedStatus(ctx, agentID)
			if err != nil {
				return
			}
			if binding.State == application.HostedPiRuntimeDegraded {
				if binding.OwnershipIndeterminate {
					return
				}
				cleanupCtx, cleanupCancel := context.WithTimeout(context.Background(), 5*time.Second)
				_ = s.rollbackHostedRegistration(cleanupCtx, agentID, agentPID, metadata)
				cleanupCancel()
				return
			}
			if binding.State == application.HostedPiRuntimeStopped {
				return
			}
			if binding.TmuxSessionID != "" {
				barrier, barrierErr := s.durableBarrier(ctx, agentPID)
				if barrierErr == nil && barrier.Completed {
					return
				}
			}
			select {
			case <-ctx.Done():
				return
			case <-time.After(10 * time.Millisecond):
			}
		}
	}()
}

func (s *Service) resolveHostedControl(ctx context.Context, agentID string) (*actor.PID, error) {
	value, err := s.system.NoSender().Ask(ctx, s.agentRegistry, &application.ResolveAgentControl{AgentID: agentID}, min(requestTimeout, boundedRemaining(ctx, requestTimeout)))
	if err != nil {
		return nil, err
	}
	resolved, ok := value.(*application.AgentControlPID)
	if !ok || !resolved.Found || resolved.PID == nil {
		return nil, errors.New("hosted agent control actor not found")
	}
	return resolved.PID, nil
}

func (s *Service) hostedStatus(ctx context.Context, agentID string) (application.HostedPiRuntimeBinding, error) {
	s.hostedMu.Lock()
	pid := s.hostedRuntimes[agentID]
	terminal, terminalExists := s.hostedTerminal[agentID]
	var registrationCleanup *registrationCleanup
	registrationPending := false
	for _, placeholder := range s.registrationPlaceholders {
		if placeholder.agentID == agentID {
			registrationPending = true
			break
		}
	}
	for _, candidate := range s.registrationCleanups {
		if candidate.agentID == agentID {
			registrationCleanup = candidate
			break
		}
	}
	s.hostedMu.Unlock()
	if pid == nil {
		if registrationPending {
			binding := application.InactiveHostedPiRuntimeBinding()
			binding.State = application.HostedPiRuntimeStarting
			binding.CleanupPending = true
			return binding, nil
		}
		if registrationCleanup != nil {
			if registrationCleanup.mu.TryLock() {
				binding := registrationCleanup.binding
				registrationCleanup.mu.Unlock()
				return binding, nil
			}
			binding := application.InactiveHostedPiRuntimeBinding()
			binding.State = application.HostedPiRuntimeStopping
			binding.CleanupPending = true
			return binding, nil
		}
		if terminalExists {
			return terminal, nil
		}
		return application.HostedPiRuntimeBinding{}, errors.New("hosted agent not found")
	}
	resolved, err := s.resolveHostedControl(ctx, agentID)
	if err != nil {
		return application.HostedPiRuntimeBinding{}, err
	}
	pid = resolved
	s.hostedMu.Lock()
	if s.hostedRuntimes[agentID] != nil {
		s.hostedRuntimes[agentID] = pid
	}
	s.hostedMu.Unlock()
	value, err := s.system.NoSender().Ask(ctx, pid, &application.HostedPiRuntimeStatus{}, min(requestTimeout, boundedRemaining(ctx, requestTimeout)))
	if err != nil {
		return application.HostedPiRuntimeBinding{}, err
	}
	binding, ok := value.(*application.HostedPiRuntimeBinding)
	if !ok {
		return application.HostedPiRuntimeBinding{}, errors.New("unexpected hosted runtime status")
	}
	return *binding, nil
}

func (s *Service) stopHostedAgent(ctx context.Context, agentID string) (application.HostedPiRuntimeBinding, error) {
	s.hostedMu.Lock()
	pid, metadata := s.hostedRuntimes[agentID], s.hostedRegistrations[agentID]
	if degraded, exists := s.hostedIndeterminate[agentID]; exists {
		s.hostedMu.Unlock()
		// Operator recovery for an ownership-indeterminate deadlock: a dead
		// runtime plus an indeterminate record otherwise blocks both admin STOP
		// and same-name recreation with no path except manual file surgery.
		// STOP accepts only proven-absence evidence (tmux server gone or the
		// exact pane dead under the guarded ownership predicate) and retires the
		// record; anything unproven stays fail-closed indeterminate.
		retired, retireErr := s.retireHostedOnProvenAbsence(ctx, agentID, degraded, metadata)
		if retireErr != nil {
			return degraded, retireErr
		}
		if retired {
			binding := degraded
			binding.State, binding.BridgeReady, binding.OwnershipIndeterminate, binding.CleanupPending = application.HostedPiRuntimeStopped, false, false, false
			return binding, nil
		}
		return degraded, application.ErrHostedOwnershipIndeterminate
	}
	var registrationID string
	var registrationPlaceholder *registrationPlaceholder
	var registrationCleanup *registrationCleanup
	for _, candidate := range s.registrationPlaceholders {
		if candidate.agentID == agentID {
			registrationPlaceholder = candidate
			break
		}
	}
	for id, candidate := range s.registrationCleanups {
		if candidate.agentID == agentID {
			registrationID, registrationCleanup = id, candidate
			break
		}
	}
	s.hostedMu.Unlock()
	if registrationPlaceholder != nil {
		select {
		case <-registrationPlaceholder.done:
			return s.stopHostedAgent(ctx, agentID)
		case <-ctx.Done():
			return application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStopping, CleanupPending: true}, ctx.Err()
		}
	}
	if pid == nil {
		if registrationCleanup != nil {
			if err := s.attemptRegistrationCleanup(ctx, registrationID, registrationCleanup); err != nil {
				return application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStopping, CleanupPending: true}, err
			}
			binding := registrationCleanup.binding
			binding.State, binding.CleanupPending = application.HostedPiRuntimeStopped, false
			return binding, nil
		}
		s.hostedMu.Lock()
		terminal, exists := s.hostedTerminal[agentID]
		_, cleanupPending := s.hostedCleanup[agentID]
		s.hostedMu.Unlock()
		if exists {
			if cleanupPending {
				if err := s.cleanupHostedMetadata(ctx, agentID); err != nil {
					return terminal, err
				}
			}
			return terminal, nil
		}
		return application.HostedPiRuntimeBinding{}, errors.New("hosted agent not found")
	}
	resolved, err := s.resolveHostedControl(ctx, agentID)
	if err != nil {
		return application.HostedPiRuntimeBinding{}, err
	}
	pid = resolved
	s.hostedMu.Lock()
	s.hostedRuntimes[agentID] = pid
	s.hostedMu.Unlock()
	if err := s.requestHostedRuntimeStop(ctx, pid, "authenticated admin stop", boundedRemaining(ctx, 5*time.Second)); err != nil {
		return application.HostedPiRuntimeBinding{}, err
	}
	for {
		binding, err := s.hostedStatus(ctx, agentID)
		if err != nil {
			return binding, err
		}
		if binding.State == application.HostedPiRuntimeStopped {
			if err := s.unregisterHostedAgent(ctx, agentID); err != nil {
				return binding, err
			}
			if err := s.retireStoppedRuntime(agentID, pid, binding, metadata); err != nil {
				return binding, err
			}
			if err := s.cleanupHostedMetadata(ctx, agentID); err != nil {
				return binding, err
			}
			return binding, nil
		}
		if binding.State == application.HostedPiRuntimeDegraded {
			reason := "hosted runtime cleanup degraded"
			if value, failureErr := s.system.NoSender().Ask(ctx, pid, &application.HostedPiRuntimeFailureStatus{}, min(requestTimeout, boundedRemaining(ctx, requestTimeout))); failureErr == nil {
				if failure, ok := value.(*application.HostedPiRuntimeFailure); ok && failure.Reason != "" {
					reason += ": " + failure.Reason
				}
			}
			return binding, errors.New(reason)
		}
		select {
		case <-ctx.Done():
			return binding, ctx.Err()
		case <-time.After(10 * time.Millisecond):
		}
	}
}

// retireHostedOnProvenAbsence implements the documented operator recovery for
// an ownership-indeterminate hosted record: it retires the durable record, the
// ownership record, and the session credential only when the exact runtime is
// proven absent (tmux server gone, or the exact pane dead and cleanup under the
// guarded ownership predicate succeeded). It returns (false, nil) when absence
// is not provable, leaving the fail-closed indeterminate state untouched.
func (s *Service) retireHostedOnProvenAbsence(ctx context.Context, agentID string, degraded application.HostedPiRuntimeBinding, metadata hostedRegistration) (bool, error) {
	records, _, err := s.durableStore.LoadAllWithQuarantine(ctx)
	if err != nil {
		return false, err
	}
	var record *application.DurableHostedRecord
	for index := range records {
		if records[index].AgentID == agentID {
			record = &records[index]
			break
		}
	}
	if record == nil {
		// No durable record remains: nothing left to recover.
		s.hostedMu.Lock()
		delete(s.hostedIndeterminate, agentID)
		delete(s.hostedTerminal, agentID)
		delete(s.hostedRegistrations, agentID)
		s.hostedMu.Unlock()
		return true, nil
	}
	credentialFile := metadata.credentialFile
	if credentialFile == "" {
		credentialFile = record.Session.CredentialFile
	}
	runtime := &hostedpi.Runtime{Config: hostedpi.Config{TmuxBinary: s.hostedAdmin.TmuxBinary, PiBinary: s.hostedAdmin.PiBinary, BridgeExtension: s.hostedAdmin.BridgeExtension, DaemonEndpoint: hostedActorEndpoint(s.hostedAdmin), CredentialFile: credentialFile, ServerName: s.hostedAdmin.ServerName, TmuxConfig: s.hostedAdmin.TmuxConfig, ProjectDirectory: record.RuntimeConfig.ProjectDirectory, StateDirectory: s.hostedAdmin.StateDirectory, SessionID: record.Session.SessionID, GenerationID: record.Session.GenerationID, CallerIdentity: record.Session.Caller}}
	absent, probeErr := runtime.ProveAbsent(ctx, degraded)
	if probeErr != nil {
		return false, errors.Join(application.ErrHostedOwnershipIndeterminate, probeErr)
	}
	if !absent {
		return false, nil
	}
	if err := hostedpi.RemoveOwnershipRecord(s.hostedAdmin.StateDirectory, degraded.RuntimeID); err != nil {
		return false, err
	}
	if credentialFile != "" {
		if err := hostedpi.RemoveCredentialFile(credentialFile); err != nil {
			return false, err
		}
	}
	if err := s.durableStore.Remove(ctx, agentID); err != nil {
		return false, err
	}
	if sessionID := record.Session.SessionID; sessionID != "" {
		_ = s.CloseSession(ctx, sessionID)
	}
	s.hostedMu.Lock()
	if s.hostedProjects[record.RuntimeConfig.ProjectDirectory] == agentID {
		delete(s.hostedProjects, record.RuntimeConfig.ProjectDirectory)
	}
	delete(s.hostedIndeterminate, agentID)
	delete(s.hostedTerminal, agentID)
	delete(s.hostedRegistrations, agentID)
	delete(s.hostedCleanup, agentID)
	s.hostedMu.Unlock()
	return true, nil
}

func (s *Service) rollbackHostedRegistration(ctx context.Context, agentID string, pid *actor.PID, metadata hostedRegistration) error {
	terminal := application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeStopped}
	if pid != nil {
		_ = s.requestHostedRuntimeStop(ctx, pid, "hosted start rollback", boundedRemaining(ctx, 5*time.Second))
	}
	for pid != nil {
		value, err := s.system.NoSender().Ask(ctx, pid, &application.HostedPiRuntimeStatus{}, min(requestTimeout, boundedRemaining(ctx, requestTimeout)))
		if err != nil {
			return err
		}
		binding, ok := value.(*application.HostedPiRuntimeBinding)
		if !ok {
			return errors.New("unexpected hosted rollback status")
		}
		terminal = *binding
		if binding.State == application.HostedPiRuntimeDegraded {
			if binding.OwnershipIndeterminate {
				return errors.New("hosted rollback ownership is indeterminate")
			}
			break
		}
		if binding.State == application.HostedPiRuntimeStopped {
			break
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(10 * time.Millisecond):
		}
	}
	if err := s.unregisterHostedAgent(ctx, agentID); err != nil {
		return err
	}
	terminal.State = application.HostedPiRuntimeStopped
	if pid != nil {
		if err := s.retireStoppedRuntime(agentID, pid, terminal, metadata); err != nil {
			return err
		}
	} else {
		terminal.CleanupPending = true
		s.hostedMu.Lock()
		s.hostedTerminal[agentID], s.hostedCleanup[agentID] = terminal, metadata
		s.hostedMu.Unlock()
	}
	if err := s.cleanupHostedMetadata(ctx, agentID); err != nil {
		return err
	}
	s.hostedMu.Lock()
	delete(s.hostedTerminal, agentID)
	s.hostedMu.Unlock()
	return nil
}

func (s *Service) unregisterHostedAgent(ctx context.Context, agentID string) error {
	result := make(chan application.UnregisterAgentResult, 1)
	if err := s.system.NoSender().Tell(ctx, s.agentRegistry, &application.UnregisterAgent{AgentID: agentID, Result: result}); err != nil {
		return err
	}
	select {
	case response := <-result:
		if !response.Completed {
			return errors.New(response.Reason)
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (s *Service) retireStoppedRuntime(agentID string, pid *actor.PID, binding application.HostedPiRuntimeBinding, metadata hostedRegistration) error {
	s.hostedMu.Lock()
	defer s.hostedMu.Unlock()
	if current := s.hostedRuntimes[agentID]; current != nil && current != pid {
		return errors.New("hosted runtime retirement identity changed")
	}
	delete(s.hostedRuntimes, agentID)
	delete(s.hostedRegistrations, agentID)
	binding.CleanupPending = true
	s.hostedTerminal[agentID] = binding
	s.hostedCleanup[agentID] = metadata
	return nil
}

func (s *Service) cleanupHostedMetadata(ctx context.Context, agentID string) error {
	s.hostedMu.Lock()
	metadata, pending := s.hostedCleanup[agentID]
	s.hostedMu.Unlock()
	if !pending {
		return nil
	}
	if metadata.sessionID != "" {
		if err := s.closeHostedSession(ctx, metadata.sessionID); err != nil {
			return fmt.Errorf("close hosted bridge session: %w", err)
		}
		metadata.sessionID = ""
		s.hostedMu.Lock()
		s.hostedCleanup[agentID] = metadata
		s.hostedMu.Unlock()
	}
	if metadata.credentialFile != "" {
		if err := s.removeHostedCredential(metadata.credentialFile); err != nil {
			return fmt.Errorf("remove hosted bridge credential: %w", err)
		}
		metadata.credentialFile = ""
		s.hostedMu.Lock()
		s.hostedCleanup[agentID] = metadata
		s.hostedMu.Unlock()
	}
	if s.durableStore != nil {
		if err := s.durableStore.Remove(ctx, agentID); err != nil {
			return fmt.Errorf("remove durable hosted record: %w", err)
		}
	}
	s.hostedMu.Lock()
	delete(s.hostedCleanup, agentID)
	for project, owner := range s.hostedProjects {
		if owner == agentID {
			delete(s.hostedProjects, project)
		}
	}
	if terminal, exists := s.hostedTerminal[agentID]; exists {
		terminal.CleanupPending = false
		s.hostedTerminal[agentID] = terminal
	}
	s.hostedMu.Unlock()
	return nil
}

func redactedLifecycleReason(operation string, err error) string {
	if err == nil {
		return operation
	}
	return operation + ": " + err.Error()
}

func validateProjectDirectory(path string) error {
	if !filepath.IsAbs(path) || path != filepath.Clean(path) || strings.HasPrefix(path, "/mnt/") {
		return errors.New("hosted project directory must be a clean absolute Unix path")
	}
	directory, err := securepath.OpenDir(path, func(current string, info os.FileInfo, final bool) error {
		stat := info.Sys().(*syscall.Stat_t)
		if final && stat.Uid != uint32(os.Getuid()) {
			return errors.New("hosted project directory ownership or mode is unsafe")
		}
		if !final && stat.Uid != 0 && stat.Uid != uint32(os.Getuid()) {
			return fmt.Errorf("hosted project ancestor %s is foreign", current)
		}
		return nil
	})
	if directory != nil {
		_ = directory.Close()
	}
	return err
}

func validAgentID(value string) bool {
	if value == "" || len(value) > 64 || value != strings.TrimSpace(value) {
		return false
	}
	for _, character := range value {
		if !(character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character >= '0' && character <= '9' || character == '-' || character == '_') {
			return false
		}
	}
	return true
}
func boundedRemaining(ctx context.Context, fallback time.Duration) time.Duration {
	if deadline, ok := ctx.Deadline(); ok {
		remaining := time.Until(deadline)
		if remaining < fallback {
			return max(remaining, time.Millisecond)
		}
	}
	return fallback
}

func bridgeLifecycleEvent(event subagentsv1.BridgeLifecycleRequest_Event) (application.BridgeLifecycleEvent, bool) {
	switch event {
	case subagentsv1.BridgeLifecycleRequest_EVENT_SESSION_START, subagentsv1.BridgeLifecycleRequest_EVENT_READY, subagentsv1.BridgeLifecycleRequest_EVENT_SESSION_SHUTDOWN, subagentsv1.BridgeLifecycleRequest_EVENT_AGENT_START, subagentsv1.BridgeLifecycleRequest_EVENT_AGENT_SETTLED:
		return application.BridgeLifecycleEvent(event), true
	default:
		return application.BridgeLifecycleUnspecified, false
	}
}

func actorModeCapability(mode subagentsv1.ActorMessageRequest_Mode) (string, bool) {
	switch mode {
	case subagentsv1.ActorMessageRequest_MODE_TELL:
		return "send", true
	case subagentsv1.ActorMessageRequest_MODE_ASK:
		return "ask", true
	default:
		return "", false
	}
}
func bridgeDeliveryKindLabel(kind application.BridgeDeliveryKind) string {
	switch kind {
	case application.BridgeDeliveryPrompt:
		return "ask"
	case application.BridgeDeliveryAbort:
		return "abort"
	case application.BridgeDeliveryShutdown:
		return "shutdown"
	default:
		return "tell"
	}
}

func actorMessageKind(mode subagentsv1.ActorMessageRequest_Mode) string {
	switch mode {
	case subagentsv1.ActorMessageRequest_MODE_TELL:
		return "Tell"
	case subagentsv1.ActorMessageRequest_MODE_ASK:
		return "Ask"
	default:
		return "Message"
	}
}

func actorControlKind(intent subagentsv1.ActorControlRequest_Intent) string {
	switch intent {
	case subagentsv1.ActorControlRequest_INTENT_ABORT:
		return "Abort"
	case subagentsv1.ActorControlRequest_INTENT_SHUTDOWN:
		return "Shutdown"
	default:
		return "Control"
	}
}

func actorControlCapability(intent subagentsv1.ActorControlRequest_Intent) (string, bool) {
	switch intent {
	case subagentsv1.ActorControlRequest_INTENT_ABORT:
		return "control_abort", true
	case subagentsv1.ActorControlRequest_INTENT_SHUTDOWN:
		return "control_shutdown", true
	default:
		return "", false
	}
}

// boundedLogAtom bounds a daemon log field to a fixed width and strips
// control characters so operator-facing log lines stay single-line and bounded.
func boundedLogAtom(value string, max int) string {
	clean := strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return ' '
		}
		return r
	}, value)
	if len(clean) > max {
		return clean[:max-1] + "…"
	}
	return clean
}

func hostedStartupFailureClass(reason string) string {
	switch reason {
	case "hosted bridge authorization denied", "hosted bridge binding rejected", "hosted bridge replacement requires an explicit fenced transition", "durable persistence is busy":
		return reason
	case "hosted bridge attachment required":
		return "hosted bridge attachment failed"
	default:
		return "hosted bridge startup rejected"
	}
}

func neutralPeerDisplay(stableID string) string {
	value, _ := terminalMetadata(stableID, 80)
	if value != "" {
		return value
	}
	return "actor"
}

func terminalMetadata(value string, limit int) (string, bool) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", true
	}
	if strings.ContainsAny(value, "\x00\r\n\t") || len(value) > limit {
		return "", false
	}
	return value, true
}

func (s *Service) updateTerminalMetadata(ctx context.Context, agentID, displayName, role string) error {
	if displayName == "" && role == "" {
		return nil
	}
	result := make(chan application.OperationResult, 1)
	if err := s.system.NoSender().Tell(ctx, s.agentRegistry, &application.UpdateAgentMetadata{AgentID: agentID, DisplayName: displayName, Role: role, Result: result}); err != nil {
		return err
	}
	select {
	case updated := <-result:
		if !updated.Completed {
			return fmt.Errorf("update terminal metadata: %s", updated.Reason)
		}
	case <-ctx.Done():
		return ctx.Err()
	}
	if s.durableStore != nil {
		records, err := s.durableStore.LoadAll(ctx)
		if err != nil {
			return err
		}
		for _, record := range records {
			if record.AgentID != agentID {
				continue
			}
			record.Binding.DisplayName = displayName
			record.Binding.Role = role
			return s.durableStore.Save(ctx, record)
		}
	}
	return nil
}

func (s *Service) ensureTerminalAgent(ctx context.Context, agentID string, displayNameRole ...string) error {
	if agentID == "" {
		return fmt.Errorf("terminal agent id is empty")
	}
	value, err := s.system.NoSender().Ask(ctx, s.agentRegistry, &application.ResolveAgentControl{AgentID: agentID}, requestTimeout)
	displayName, role := "", ""
	if len(displayNameRole) > 0 {
		displayName = displayNameRole[0]
	}
	if len(displayNameRole) > 1 {
		role = displayNameRole[1]
	}
	if err == nil {
		if resolved, ok := value.(*application.AgentControlPID); ok && resolved.Found {
			return s.updateTerminalMetadata(ctx, agentID, displayName, role)
		}
	}
	registered := make(chan application.RegisterAgentResult, 1)
	durable := application.DurableHostedRecord{SchemaVersion: application.DurableHostedSchemaVersion, OwnerUID: os.Getuid(), AgentID: agentID, AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: agentID}, AllowedCapabilities: []string{"observe", "send", "ask", "prompt", "control_abort", "control_shutdown"}, Retention: "bounded", Recovery: "terminal-reattach", Binding: application.InactiveHostedPiRuntimeBinding()}
	durable.Binding.DisplayName = displayName
	durable.Binding.Role = role
	registration := application.RegisterAgent{AgentID: agentID, Role: role, DisplayName: displayName, AuthorityBinding: durable.AuthorityBinding, HostedPiRuntime: durable.Binding, AllowedCapability: append([]string(nil), durable.AllowedCapabilities...), Retention: durable.Retention, Recovery: durable.Recovery, PersistencePID: s.persistencePID, PersistenceSupervisor: s.persistenceSupervisor, IntrospectionRunner: s.introspectionRunner, DurableRecord: &durable}
	if err := s.system.NoSender().Tell(ctx, s.agentRegistry, &application.CoordinateAgentRegistration{OperationID: "terminal-agent-" + agentID, Registration: registration, Result: registered}); err != nil {
		return err
	}
	select {
	case result := <-registered:
		if result.Created || result.Reason == "agent already registered" {
			return nil
		}
		return fmt.Errorf("register terminal agent: %s", result.Reason)
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (s *Service) terminalActorMessageHighWater(ctx context.Context, agentID string) (uint64, error) {
	value, err := s.system.NoSender().Ask(ctx, s.agentRegistry, &application.ResolveAgentControl{AgentID: agentID}, requestTimeout)
	if err != nil {
		return 0, err
	}
	resolved, ok := value.(*application.AgentControlPID)
	if !ok || !resolved.Found || resolved.PID == nil {
		return 0, fmt.Errorf("terminal actor unavailable")
	}
	value, err = s.system.NoSender().Ask(ctx, resolved.PID, &application.ActorMessageHighWaterRequest{}, requestTimeout)
	if err != nil {
		return 0, err
	}
	result, ok := value.(*application.ActorMessageHighWaterResult)
	if !ok {
		return 0, fmt.Errorf("terminal actor mutation high-water unavailable")
	}
	return result.HighWater, nil
}

func authenticatedHostedSource(principal string) (string, bool) {
	const prefix = "hosted:"
	if !strings.HasPrefix(principal, prefix) || len(principal) == len(prefix) {
		return "", false
	}
	return strings.TrimPrefix(principal, prefix), true
}
func authenticatedClientSource(principal string) (string, bool) {
	const prefix = "client:"
	if !strings.HasPrefix(principal, prefix) || len(principal) == len(prefix) {
		return "", false
	}
	return principal, true
}

func randomHandle() (string, error) {
	buffer := make([]byte, 32)
	if _, err := rand.Read(buffer); err != nil {
		return "", fmt.Errorf("generate agent handle: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(buffer), nil
}
