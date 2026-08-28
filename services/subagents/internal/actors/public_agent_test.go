package actors

import (
	"context"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
	goaktlog "github.com/tochemey/goakt/v4/log"
)

func TestPublicAgentDirectoryAuthorizationPrivateAndStaleNode(t *testing.T) {
	ctx := context.Background()
	system, err := actor.NewActorSystem("public-dir-test", actor.WithLogger(goaktlog.DiscardLogger))
	if err != nil {
		t.Fatal(err)
	}
	if err := system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = system.Stop(context.Background()) })
	dir, err := system.Spawn(ctx, "public-directory", NewPublicAgentDirectoryActor("local", map[string]application.PublicNode{"vps": {Identity: "vps", Host: "127.0.0.1", Port: 1, Stale: true}}))
	if err != nil {
		t.Fatal(err)
	}
	credential := []byte("0123456789abcdef0123456789abcdef")
	if err := system.NoSender().Tell(ctx, dir, &application.StageSession{Session: application.OpenSession{SessionID: "s", GenerationID: "g", Caller: "pm", Credential: credential, Capabilities: []string{"observe", "tell", "ask"}, ExpiresAt: time.Now().Add(time.Minute)}, Registry: application.AgentRegistry}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(20 * time.Millisecond)
	unauth, err := system.NoSender().Ask(ctx, dir, &application.CreatePublicAgent{SessionID: "s", GenerationID: "g", Caller: "pm", Credential: credential, AgentID: "ui_remote_qa", Placement: application.PublicAgentPlacement{NodeIdentity: "vps"}}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if got := unauth.(*application.PublicAgentCreateResult); got.Reason != "session authorization denied" {
		t.Fatalf("authorization must happen before placement lookup, got %#v", got)
	}
	if err := system.NoSender().Tell(ctx, dir, &application.StageSession{Session: application.OpenSession{SessionID: "admin", GenerationID: "g", Caller: "pm", Credential: credential, Capabilities: []string{"observe", "admin", "tell", "ask"}, ExpiresAt: time.Now().Add(time.Minute)}, Registry: application.AgentRegistry}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(20 * time.Millisecond)
	private, err := system.NoSender().Ask(ctx, dir, &application.CreatePublicAgent{SessionID: "admin", GenerationID: "g", Caller: "pm", Credential: credential, AgentID: "ui_remote_qa", Private: true, Placement: application.PublicAgentPlacement{NodeIdentity: "vps"}}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if got := private.(*application.PublicAgentCreateResult); got.Reason != "invalid public agent" {
		t.Fatalf("private actor was not excluded: %#v", got)
	}
	stale, err := system.NoSender().Ask(ctx, dir, &application.CreatePublicAgent{SessionID: "admin", GenerationID: "g", Caller: "pm", Credential: credential, AgentID: "ui_remote_qa", Placement: application.PublicAgentPlacement{NodeIdentity: "vps"}}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if got := stale.(*application.PublicAgentCreateResult); got.Reason != "placement node unavailable" {
		t.Fatalf("stale node accepted: %#v", got)
	}
}
