package service

import (
	"context"
	"errors"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

type scriptedListener struct {
	mu       sync.Mutex
	errors   []error
	calls    int
	closed   chan struct{}
	closeErr error
	once     sync.Once
}

func newScriptedListener(errs ...error) *scriptedListener {
	return &scriptedListener{errors: errs, closed: make(chan struct{})}
}
func (l *scriptedListener) Accept() (net.Conn, error) {
	l.mu.Lock()
	l.calls++
	if len(l.errors) > 0 {
		err := l.errors[0]
		l.errors = l.errors[1:]
		l.mu.Unlock()
		return nil, err
	}
	l.mu.Unlock()
	<-l.closed
	return nil, net.ErrClosed
}
func (l *scriptedListener) Close() error   { l.once.Do(func() { close(l.closed) }); return l.closeErr }
func (*scriptedListener) Addr() net.Addr   { return fakeAddr("scripted") }
func (l *scriptedListener) callCount() int { l.mu.Lock(); defer l.mu.Unlock(); return l.calls }

type fakeAddr string

func (a fakeAddr) Network() string { return string(a) }
func (a fakeAddr) String() string  { return string(a) }

type temporaryAcceptError struct{ message string }

func (e temporaryAcceptError) Error() string { return e.message }
func (temporaryAcceptError) Temporary() bool { return true }
func (temporaryAcceptError) Timeout() bool   { return false }

func TestStopPersistsFirstFailure(t *testing.T) {
	closeFailure := errors.New("forced listener cleanup failure")
	listener := newScriptedListener()
	listener.closeErr = closeFailure
	daemon, err := startWithListener(context.Background(), listener)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	first := daemon.Stop(ctx)
	second := daemon.Stop(context.Background())
	if !errors.Is(first, closeFailure) || !errors.Is(second, closeFailure) || first.Error() != second.Error() {
		t.Fatalf("stop result was not durable: first=%v second=%v", first, second)
	}
}

func TestAcceptLoopRetriesTemporaryErrorsThenSurfacesPermanentFailure(t *testing.T) {
	permanent := errors.New("forced permanent accept failure")
	listener := newScriptedListener(temporaryAcceptError{"temporary-one"}, temporaryAcceptError{"temporary-two"}, permanent)
	daemon, err := startWithListener(context.Background(), listener)
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		health, healthErr := daemon.Health(context.Background())
		if healthErr == nil && !health.Ready {
			if listener.callCount() != 3 || health.Status != "admission degraded" {
				t.Fatalf("unexpected retry/degraded state: calls=%d health=%#v", listener.callCount(), health)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if stopErr := daemon.Stop(ctx); !errors.Is(stopErr, permanent) {
				t.Fatalf("permanent accept error not durable: %v", stopErr)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("permanent accept failure did not degrade readiness")
}

func TestSessionCleanupRetriesProductionBoundedMailboxOverflow(t *testing.T) {
	listener := newScriptedListener()
	daemon, err := startWithListener(context.Background(), listener)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	registration := application.RegisterAgent{AgentID: "overflow-agent", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "run"}, HostedPiRuntime: application.InactiveHostedPiRuntimeBinding(), AllowedCapability: []string{"observe"}, Retention: "explicit", Recovery: "metadata-only"}
	if err := daemon.RegisterAgent(context.Background(), registration); err != nil {
		t.Fatal(err)
	}
	credential := []byte(strings.Repeat("o", 32))
	session := application.OpenSession{SessionID: "overflow-session", GenerationID: "overflow-generation", Caller: "caller", Credential: credential, Capabilities: []string{"observe"}, ExpiresAt: time.Now().Add(time.Hour)}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := daemon.OpenSession(ctx, session); err != nil {
		t.Fatal(err)
	}
	routeAny, err := daemon.system.NoSender().Ask(ctx, daemon.agentRegistry, &application.AuthorizeAgentAccess{SessionID: session.SessionID, GenerationID: session.GenerationID, Caller: session.Caller, Credential: credential, AgentID: "overflow-agent", Capabilities: []string{"observe"}}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	route := routeAny.(*application.AgentRoute)
	events, err := daemon.system.Subscribe()
	if err != nil {
		t.Fatal(err)
	}
	defer daemon.system.Unsubscribe(events)
	var flood sync.WaitGroup
	for worker := 0; worker < 128; worker++ {
		flood.Add(1)
		go func() {
			defer flood.Done()
			for index := 0; index < 5000; index++ {
				_ = daemon.system.NoSender().Tell(context.Background(), daemon.agentRegistry, &application.ListAgents{})
				_ = daemon.system.NoSender().Tell(context.Background(), route.PID, &application.Subscribers{})
			}
		}()
	}
	closeResult := make(chan error, 1)
	go func() { closeResult <- daemon.CloseSession(ctx, session.SessionID) }()
	flood.Wait()
	deadletters := 0
	for event := range events.Iterator() {
		if _, ok := event.Payload().(*actor.Deadletter); ok {
			deadletters++
		}
	}
	if deadletters == 0 {
		t.Fatal("production bounded mailboxes did not publish overflow deadletters")
	}
	if closeErr := <-closeResult; closeErr != nil {
		t.Fatalf("coordinator did not retry cleanup after overflow: %v", closeErr)
	}
	if routeResult, askErr := daemon.system.NoSender().Ask(ctx, daemon.agentRegistry, &application.AuthorizeAgentAccess{SessionID: session.SessionID, GenerationID: session.GenerationID, Caller: session.Caller, Credential: credential, AgentID: "overflow-agent", Capabilities: []string{"observe"}}, time.Second); askErr != nil || routeResult.(*application.AgentRoute).Allowed {
		t.Fatalf("closed session remained authorized: %#v %v", routeResult, askErr)
	}
	if !route.PID.IsRunning() {
		t.Fatal("global AgentActor stopped during session cleanup")
	}
}

func TestOpenSessionCompensatesPartialRegistryFailureWithoutGhost(t *testing.T) {
	listener := newScriptedListener()
	daemon, err := startWithListener(context.Background(), listener)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	probeSystem := daemon.system.NoSender()
	conflictCredential := []byte(strings.Repeat("c", 32))
	conflict := application.OpenSession{SessionID: "partial-session", GenerationID: "conflict-generation", Caller: "conflict", Credential: conflictCredential, Capabilities: []string{"observe"}, ExpiresAt: time.Now().Add(time.Hour)}
	ack := make(chan application.SessionStageAck, 1)
	collector, spawnErr := daemon.system.Spawn(context.Background(), "partial-ack", &stageAckCollector{results: ack})
	if spawnErr != nil {
		t.Fatal(spawnErr)
	}
	if tellErr := probeSystem.Tell(context.Background(), daemon.agentRegistry, &application.StageSession{Session: conflict, Registry: application.AgentRegistry, Acknowledge: collector}); tellErr != nil {
		t.Fatal(tellErr)
	}
	select {
	case <-ack:
	case <-time.After(time.Second):
		t.Fatal("conflict stage was not acknowledged")
	}
	candidateCredential := []byte(strings.Repeat("d", 32))
	candidate := application.OpenSession{SessionID: "partial-session", GenerationID: "candidate-generation", Caller: "candidate", Credential: candidateCredential, Capabilities: []string{"observe"}, ExpiresAt: time.Now().Add(time.Hour)}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := daemon.OpenSession(ctx, candidate); err == nil {
		t.Fatal("partially conflicting open succeeded")
	}
	value, askErr := probeSystem.Ask(ctx, daemon.sessionRegistry, &application.SessionAuthorization{SessionID: candidate.SessionID, GenerationID: candidate.GenerationID, Caller: candidate.Caller, Credential: candidateCredential, Capability: "observe"}, time.Second)
	if askErr != nil || value.(*application.AuthorizationResult).Allowed {
		t.Fatalf("partial open left SessionRegistry ghost: %#v %v", value, askErr)
	}
}

type stageAckCollector struct {
	results chan<- application.SessionStageAck
}

func (*stageAckCollector) PreStart(*actor.Context) error { return nil }
func (*stageAckCollector) PostStop(*actor.Context) error { return nil }
func (a *stageAckCollector) Receive(ctx *actor.ReceiveContext) {
	if message, ok := ctx.Message().(*application.SessionStageAck); ok {
		a.results <- *message
		return
	}
	ctx.Unhandled()
}

func TestSessionExpiryUsesAcknowledgedCleanupAndReleasesActivePlan(t *testing.T) {
	listener := newScriptedListener()
	daemon, err := startWithListener(context.Background(), listener)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = daemon.Stop(ctx)
	})
	registration := application.RegisterAgent{AgentID: "expiry-agent", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "run"}, HostedPiRuntime: application.InactiveHostedPiRuntimeBinding(), AllowedCapability: []string{"observe"}, Retention: "explicit", Recovery: "metadata-only"}
	if err := daemon.RegisterAgent(context.Background(), registration); err != nil {
		t.Fatal(err)
	}
	credential := []byte(strings.Repeat("e", 32))
	session := application.OpenSession{SessionID: "expiry-session", GenerationID: "expiry-generation", Caller: "caller", Credential: credential, Capabilities: []string{"observe"}, ExpiresAt: time.Now().Add(300 * time.Millisecond)}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := daemon.OpenSession(ctx, session); err != nil {
		t.Fatal(err)
	}
	routeAny, err := daemon.system.NoSender().Ask(ctx, daemon.agentRegistry, &application.AuthorizeAgentAccess{SessionID: session.SessionID, GenerationID: session.GenerationID, Caller: session.Caller, Credential: credential, AgentID: "expiry-agent", Capabilities: []string{"observe"}}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	route := routeAny.(*application.AgentRoute)
	attachedAny, err := daemon.system.NoSender().Ask(ctx, route.PID, &application.AttachAgent{SessionID: session.SessionID, GenerationID: session.GenerationID, Principal: session.Caller, AgentID: "expiry-agent", RequestedCapabilities: []string{"observe"}, IssuedHandle: "expiry-handle"}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	attached := attachedAny.(*application.AttachResult)
	subscription := make(chan application.OperationResult, 1)
	if err := daemon.system.NoSender().Tell(ctx, route.PID, &application.SubscribeAgent{SessionID: session.SessionID, GenerationID: session.GenerationID, Principal: session.Caller, AgentID: "expiry-agent", Handle: attached.Handle, Fence: attached.Fence, Result: subscription}); err != nil {
		t.Fatal(err)
	}
	select {
	case result := <-subscription:
		if !result.Completed {
			t.Fatalf("projection did not acknowledge TopicActor subscription: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("projection subscription acknowledgement timed out")
	}
	time.Sleep(350 * time.Millisecond)
	value, askErr := daemon.system.NoSender().Ask(ctx, daemon.sessionRegistry, &application.SessionAuthorization{SessionID: session.SessionID, GenerationID: session.GenerationID, Caller: session.Caller, Credential: credential, Capability: "observe"}, time.Second)
	if askErr != nil || value.(*application.AuthorizationResult).Allowed {
		t.Fatalf("expired registry grant survived: %#v %v", value, askErr)
	}
	if err := daemon.OpenSession(ctx, session); err == nil {
		t.Fatal("expired session/generation was reused")
	}
	lateAny, lateErr := daemon.system.NoSender().Ask(ctx, route.PID, &application.SubscribeAgent{SessionID: session.SessionID, GenerationID: session.GenerationID, Principal: session.Caller, AgentID: "expiry-agent", Handle: attached.Handle, Fence: attached.Fence}, time.Second)
	if lateErr != nil || lateAny.(*application.OperationResult).Completed {
		t.Fatalf("expired attachment survived fanout cleanup: %#v %v", lateAny, lateErr)
	}
	deadline := time.Now().Add(time.Second)
	for {
		stats, statsErr := daemon.system.TopicStats(ctx, "subagents.agent.expiry-agent", time.Second)
		if statsErr == nil && stats.LocalSubscriberCount() == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("expired projection remained subscribed: %#v %v", stats, statsErr)
		}
		time.Sleep(5 * time.Millisecond)
	}
	if !route.PID.IsRunning() {
		t.Fatal("expiry stopped the global AgentActor")
	}
}

func TestAcceptLoopBoundsTemporaryRetries(t *testing.T) {
	listener := newScriptedListener(temporaryAcceptError{"one"}, temporaryAcceptError{"two"}, temporaryAcceptError{"three"}, temporaryAcceptError{"four"})
	daemon, err := startWithListener(context.Background(), listener)
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		health, _ := daemon.Health(context.Background())
		if !health.Ready {
			if listener.callCount() != 4 {
				t.Fatalf("temporary retry bound used %d accepts", listener.callCount())
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = daemon.Stop(ctx)
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("temporary retry exhaustion did not degrade readiness")
}
