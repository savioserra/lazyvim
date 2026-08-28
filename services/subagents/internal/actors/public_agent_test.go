package actors

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	remotingcfg "github.com/savioserra/lazyvim/services/subagents/internal/remoting"
	"github.com/tochemey/goakt/v4/actor"
	goaktlog "github.com/tochemey/goakt/v4/log"
	"github.com/tochemey/goakt/v4/remote"
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
	stage := &application.StageSession{Session: application.OpenSession{SessionID: "s", GenerationID: "g", Caller: "pm", Credential: credential, Capabilities: []string{"observe", "tell", "ask"}, ExpiresAt: time.Now().Add(time.Minute)}, Registry: application.AgentRegistry}
	if err := system.NoSender().Tell(ctx, dir, stage); err != nil {
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

	stageAdmin := &application.StageSession{Session: application.OpenSession{SessionID: "admin", GenerationID: "g", Caller: "pm", Credential: credential, Capabilities: []string{"observe", "admin", "tell", "ask"}, ExpiresAt: time.Now().Add(time.Minute)}, Registry: application.AgentRegistry}
	if err := system.NoSender().Tell(ctx, dir, stageAdmin); err != nil {
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

func TestPublicAgentSerializerRoundTrip(t *testing.T) {
	config := remote.NewConfig("127.0.0.1", freePort(t), remotingcfg.PublicAgentSerializers()...)
	serializer := config.Serializer(&application.PublicAgentAsk{})
	original := &application.PublicAgentAsk{DedupeID: "d", Payload: []byte("hello")}
	payload, err := serializer.Serialize(original)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := serializer.Deserialize(payload)
	if err != nil {
		t.Fatal(err)
	}
	ask, ok := decoded.(*application.PublicAgentAsk)
	if !ok || ask.DedupeID != original.DedupeID || string(ask.Payload) != string(original.Payload) {
		t.Fatalf("round trip mismatch: %#v", decoded)
	}
}

func TestTwoNodePublicAgentRemoteLookupTellAsk(t *testing.T) {
	ctx := context.Background()
	localPort, remotePort := freePort(t), freePort(t)
	local := newRemoteSystem(t, "local", localPort)
	vps := newRemoteSystem(t, "vps", remotePort)
	for _, sys := range []actor.ActorSystem{local, vps} {
		if err := sys.Start(ctx); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = sys.Stop(context.Background()) })
		if err := sys.Register(ctx, &PublicAgentActor{}); err != nil {
			t.Fatal(err)
		}
	}
	dir, err := local.Spawn(ctx, "public-directory", NewPublicAgentDirectoryActor("local", map[string]application.PublicNode{"vps": {Identity: "vps", Host: "127.0.0.1", Port: remotePort}}))
	if err != nil {
		t.Fatal(err)
	}
	credential := []byte("0123456789abcdef0123456789abcdef")
	if err := local.NoSender().Tell(ctx, dir, &application.StageSession{Session: application.OpenSession{SessionID: "s", GenerationID: "g", Caller: "pm", Credential: credential, Capabilities: []string{"observe", "admin", "tell", "ask"}, ExpiresAt: time.Now().Add(time.Minute)}, Registry: application.AgentRegistry}); err != nil {
		t.Fatal(err)
	}
	time.Sleep(20 * time.Millisecond)
	created, err := local.NoSender().Ask(ctx, dir, &application.CreatePublicAgent{SessionID: "s", GenerationID: "g", Caller: "pm", Credential: credential, AgentID: "ui_remote_qa", Role: "qa", DisplayName: "Remote QA", Placement: application.PublicAgentPlacement{NodeIdentity: "vps"}}, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	create := created.(*application.PublicAgentCreateResult)
	if !create.Created || create.Record.HomeNode != "vps" || create.Record.ActorName == "" {
		t.Fatalf("remote create failed: %#v", create)
	}
	if exists, err := vps.ActorExists(ctx, create.Record.ActorName); err != nil || !exists {
		t.Fatalf("actor was not created on vps: exists=%v err=%v", exists, err)
	}
	routed, err := local.NoSender().Ask(ctx, dir, &application.RoutePublicAgent{SessionID: "s", GenerationID: "g", Caller: "pm", Credential: credential, AgentID: "ui_remote_qa", Capabilities: []string{"tell"}}, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	route := routed.(*application.PublicAgentRouteResult)
	if !route.Allowed || route.PID == nil {
		t.Fatalf("route failed: %#v", route)
	}
	if err := local.NoSender().Tell(ctx, route.PID, &application.PublicAgentTell{DedupeID: "tell-1", Payload: []byte("tell")}); err != nil {
		t.Fatal(err)
	}
	answer, err := local.NoSender().Ask(ctx, route.PID, &application.PublicAgentAsk{DedupeID: "ask-1", Payload: []byte("ask")}, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	reply := answer.(*application.PublicAgentReply)
	if !reply.Completed || string(reply.Payload) != "ask" {
		t.Fatalf("ask reply mismatch: %#v", reply)
	}
}

func newRemoteSystem(t *testing.T, name string, port int) actor.ActorSystem {
	t.Helper()
	options := append([]remote.Option{}, remotingcfg.PublicAgentSerializers()...)
	system, err := actor.NewActorSystem("public-agent-"+name, actor.WithLogger(goaktlog.DiscardLogger), actor.WithRemote(remote.NewConfig("127.0.0.1", port, options...)))
	if err != nil {
		t.Fatal(err)
	}
	return system
}

func freePort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}
