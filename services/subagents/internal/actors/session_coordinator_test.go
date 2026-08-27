package actors_test

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
	"github.com/tochemey/goakt/v4/testkit"
)

func TestSessionCoordinatorAbandonedResultChannelDoesNotBlockMailbox(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	left, _ := kit.ActorSystem().Spawn(ctx, "nonblocking-result-left", &controlledRegistry{})
	right, _ := kit.ActorSystem().Spawn(ctx, "nonblocking-result-right", &controlledRegistry{})
	coordinator, err := kit.ActorSystem().Spawn(ctx, "nonblocking-result-coordinator", actors.NewSessionCoordinator(left, right))
	if err != nil {
		t.Fatal(err)
	}
	abandoned := make(chan application.CoordinationResult)
	if err := kit.ActorSystem().NoSender().Tell(ctx, coordinator, &application.CoordinateOpen{Session: application.OpenSession{}, Result: abandoned}); err != nil {
		t.Fatal(err)
	}
	result := make(chan application.CoordinationResult, 1)
	if err := kit.ActorSystem().NoSender().Tell(ctx, coordinator, &application.CoordinateOpen{Session: application.OpenSession{}, Result: result}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-result:
	case <-time.After(time.Second):
		t.Fatal("abandoned result channel blocked the coordinator mailbox")
	}
}

func TestCloseDuringOpeningWaitsForCleanupCommitAcknowledgements(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	stages := make(chan struct{}, 32)
	commits := make(chan struct{}, 32)
	leftActor := &controlledRegistry{stages: stages, commits: commits}
	rightActor := &controlledRegistry{stages: stages, commits: commits}
	left, err := kit.ActorSystem().Spawn(ctx, "controlled-session-registry", leftActor)
	if err != nil {
		t.Fatal(err)
	}
	right, err := kit.ActorSystem().Spawn(ctx, "controlled-agent-registry", rightActor)
	if err != nil {
		t.Fatal(err)
	}
	coordinator, err := kit.ActorSystem().Spawn(ctx, "controlled-session-coordinator", actors.NewSessionCoordinator(left, right))
	if err != nil {
		t.Fatal(err)
	}

	openResult := make(chan application.CoordinationResult, 1)
	closeResult := make(chan application.CoordinationResult, 1)
	session := application.OpenSession{SessionID: "opening-close-session", GenerationID: "opening-close-generation", Caller: "caller", Credential: []byte("credential"), Capabilities: []string{"observe"}, ExpiresAt: time.Now().Add(time.Hour)}
	if err := kit.ActorSystem().NoSender().Tell(ctx, coordinator, &application.CoordinateOpen{Session: session, Result: openResult}); err != nil {
		t.Fatal(err)
	}
	waitSignals(t, stages, 2, "initial stage deliveries")
	if err := kit.ActorSystem().NoSender().Tell(ctx, coordinator, &application.CoordinateClose{SessionID: session.SessionID, GenerationID: session.GenerationID, Result: closeResult}); err != nil {
		t.Fatal(err)
	}
	assertNoCoordinationResult(t, closeResult, "close acknowledged before opening completed")

	for _, pid := range []*goakt.PID{left, right} {
		if err := kit.ActorSystem().NoSender().Tell(ctx, pid, releaseStage{}); err != nil {
			t.Fatal(err)
		}
	}
	select {
	case result := <-openResult:
		if !result.Allowed || result.Completed {
			t.Fatalf("open requester received close result: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("open requester was not acknowledged")
	}
	waitSignals(t, commits, 2, "cleanup commit deliveries")
	time.Sleep(4 * 10 * time.Millisecond)
	if leftActor.commitDeliveries.Load() < 2 || rightActor.commitDeliveries.Load() < 2 {
		t.Fatalf("unacknowledged cleanup was not retried: left=%d right=%d", leftActor.commitDeliveries.Load(), rightActor.commitDeliveries.Load())
	}
	assertNoCoordinationResult(t, closeResult, "close acknowledged before commit acknowledgements")
	for _, pid := range []*goakt.PID{left, right} {
		if err := kit.ActorSystem().NoSender().Tell(ctx, pid, releaseCommit{}); err != nil {
			t.Fatal(err)
		}
	}
	select {
	case result := <-closeResult:
		if !result.Completed || result.Allowed {
			t.Fatalf("close requester received open result: %#v", result)
		}
	case <-time.After(time.Second):
		t.Fatal("close requester was not acknowledged after cleanup commits")
	}
}

func TestSessionCoordinatorRetryExhaustionCompensatesPartialOpen(t *testing.T) {
	ctx := context.Background()
	kit := testkit.New(ctx, t)
	t.Cleanup(func() { kit.Shutdown(ctx) })
	stages := make(chan struct{}, 32)
	commits := make(chan struct{}, 32)
	leftActor := &controlledRegistry{stages: stages, commits: commits}
	left, err := kit.ActorSystem().Spawn(ctx, "partial-open-session-registry", leftActor)
	if err != nil {
		t.Fatal(err)
	}
	right, err := kit.ActorSystem().Spawn(ctx, "partial-open-silent-registry", &silentRegistry{})
	if err != nil {
		t.Fatal(err)
	}
	coordinator, err := kit.ActorSystem().Spawn(ctx, "partial-open-coordinator", actors.NewSessionCoordinator(left, right))
	if err != nil {
		t.Fatal(err)
	}
	openResult := make(chan application.CoordinationResult, 1)
	session := application.OpenSession{SessionID: "partial-session", GenerationID: "partial-generation", Caller: "caller", Credential: []byte("credential"), Capabilities: []string{"observe"}, ExpiresAt: time.Now().Add(time.Hour)}
	if err := kit.ActorSystem().NoSender().Tell(ctx, coordinator, &application.CoordinateOpen{Session: session, Result: openResult}); err != nil {
		t.Fatal(err)
	}
	waitSignals(t, stages, 1, "partial stage delivery")
	if err := kit.ActorSystem().NoSender().Tell(ctx, left, releaseStage{}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-commits:
	case <-time.After(6 * time.Second):
		t.Fatal("timed out waiting for compensating commit after retry exhaustion")
	}
	if leftActor.commitDeliveries.Load() == 0 {
		t.Fatal("partial stage was not compensated")
	}
}

type silentRegistry struct{}

func (*silentRegistry) PreStart(*goakt.Context) error     { return nil }
func (*silentRegistry) PostStop(*goakt.Context) error     { return nil }
func (*silentRegistry) Receive(ctx *goakt.ReceiveContext) { ctx.Unhandled() }

type releaseStage struct{}
type releaseCommit struct{}

type controlledRegistry struct {
	stages           chan<- struct{}
	commits          chan<- struct{}
	stage            *application.StageSession
	commit           *application.CommitSessionClose
	commitDeliveries atomic.Int32
}

func (*controlledRegistry) PreStart(*goakt.Context) error { return nil }
func (*controlledRegistry) PostStop(*goakt.Context) error { return nil }
func (r *controlledRegistry) Receive(ctx *goakt.ReceiveContext) {
	switch message := ctx.Message().(type) {
	case *application.StageSession:
		r.stage = message
		r.stages <- struct{}{}
	case releaseStage:
		if r.stage != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), r.stage.Acknowledge, &application.SessionStageAck{SessionID: r.stage.Session.SessionID, GenerationID: r.stage.Session.GenerationID, Registry: r.stage.Registry, Accepted: true})
		}
	case *application.PrepareSessionClose:
		_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), message.Acknowledge, &application.SessionPrepareAck{SessionID: message.SessionID, GenerationID: message.GenerationID, Registry: message.Registry})
	case *application.CommitSessionClose:
		r.commit = message
		r.commitDeliveries.Add(1)
		r.commits <- struct{}{}
	case releaseCommit:
		if r.commit != nil {
			_ = ctx.Self().Tell(context.WithoutCancel(ctx.Context()), r.commit.Acknowledge, &application.SessionCommitAck{SessionID: r.commit.SessionID, GenerationID: r.commit.GenerationID, Registry: r.commit.Registry})
		}
	default:
		ctx.Unhandled()
	}
}

func waitSignals(t *testing.T, signals <-chan struct{}, count int, label string) {
	t.Helper()
	for range count {
		select {
		case <-signals:
		case <-time.After(time.Second):
			t.Fatalf("timed out waiting for %s", label)
		}
	}
}

func assertNoCoordinationResult(t *testing.T, results <-chan application.CoordinationResult, label string) {
	t.Helper()
	select {
	case result := <-results:
		t.Fatalf("%s: %#v", label, result)
	case <-time.After(25 * time.Millisecond):
	}
}
