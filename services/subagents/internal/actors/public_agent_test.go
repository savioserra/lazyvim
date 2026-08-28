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

func TestPublicAgentDirectoryLearnsRemoteHostedAgentsFromTopicEvents(t *testing.T) {
	ctx := context.Background()
	system, err := actor.NewActorSystem("public-dir-events-test", actor.WithLogger(goaktlog.DiscardLogger), actor.WithPubSub(), actor.WithMessageRetention(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if err := system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = system.Stop(context.Background()) })
	dir, err := system.Spawn(ctx, "public-directory-events", NewPublicAgentDirectoryActor("local", map[string]application.PublicNode{"vps": {Identity: "vps", Host: "127.0.0.1", Port: 17213}}))
	if err != nil {
		t.Fatal(err)
	}
	waitForTopicSubscriber(t, system, publicAgentDirectoryTopic)
	credential := []byte("0123456789abcdef0123456789abcdef")
	if err := system.NoSender().Tell(ctx, dir, &application.StageSession{Session: application.OpenSession{SessionID: "s", GenerationID: "g", Caller: "pm", Credential: credential, Capabilities: []string{"observe", "tell", "ask"}, ExpiresAt: time.Now().Add(time.Minute)}, Registry: application.AgentRegistry}); err != nil {
		t.Fatal(err)
	}
	reference := application.AgentReference{AgentID: "ui_remote_qa", LifecycleRevision: 2, Role: "qa", DisplayName: "Remote QA", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned}}
	published := &application.PublicAgentDirectoryEvent{Operation: "upsert", NodeIdentity: "vps", AgentID: "ui_remote_qa", ActorName: application.HostedPlacementAuthorityName("vps"), Epoch: 1, Sequence: 1, Reference: reference}
	if err := system.NoSender().Tell(ctx, system.TopicActor(), actor.NewPublish("vps:ui_remote_qa:1", publicAgentDirectoryTopic, published)); err != nil {
		t.Fatal(err)
	}
	waitForPublicList(t, system, dir, credential, 1)
	removed := &application.PublicAgentDirectoryEvent{Operation: "remove", NodeIdentity: "vps", AgentID: "ui_remote_qa", ActorName: application.HostedPlacementAuthorityName("vps"), Epoch: 1, Sequence: 2}
	if err := system.NoSender().Tell(ctx, system.TopicActor(), actor.NewPublish("vps:ui_remote_qa:2", publicAgentDirectoryTopic, removed)); err != nil {
		t.Fatal(err)
	}
	waitForPublicList(t, system, dir, credential, 0)
	if err := system.NoSender().Tell(ctx, system.TopicActor(), actor.NewPublish("vps:ui_remote_qa:old", publicAgentDirectoryTopic, published)); err != nil {
		t.Fatal(err)
	}
	time.Sleep(50 * time.Millisecond)
	waitForPublicList(t, system, dir, credential, 0)
}

func waitForTopicSubscriber(t *testing.T, system actor.ActorSystem, topic string) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		stats, err := system.TopicStats(context.Background(), topic, time.Second)
		if err == nil && stats.LocalSubscriberCount() > 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("topic %s had no local subscriber", topic)
}

func waitForPublicList(t *testing.T, system actor.ActorSystem, dir *actor.PID, credential []byte, want int) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		value, err := system.NoSender().Ask(context.Background(), dir, &application.ListAgents{SessionID: "s", GenerationID: "g", Caller: "pm", Credential: credential}, time.Second)
		if err == nil {
			list := value.(*application.AgentList)
			if len(list.Agents) == want {
				return
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("public directory list did not reach %d agents", want)
}
