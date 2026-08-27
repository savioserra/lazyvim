package actors_test

import (
	"context"
	"testing"
	"time"

	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
)

type bridgeHarness struct {
	system     goakt.ActorSystem
	pid        *goakt.PID
	agent      string
	session    string
	generation string
	principal  string
	handle     string
	fence      uint64
}

func newBridgeHarness(t *testing.T, name, agent, source string) *bridgeHarness {
	t.Helper()
	ctx := context.Background()
	system, err := goakt.NewActorSystem(name, goakt.WithPubSub(), goakt.WithMessageRetention(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if err := system.Start(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		stop, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = system.Stop(stop)
	})
	registration := &application.RegisterAgent{AgentID: agent, AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingHostedOwned, HostedRuntimeID: "runtime-" + agent}, HostedPiRuntime: application.HostedPiRuntimeBinding{State: application.HostedPiRuntimeReady, RuntimeID: "runtime-" + agent, Incarnation: 1, BridgeReady: true}, AllowedCapability: []string{"observe", "hosted_bridge", "send", "ask", "prompt"}, Retention: "explicit", Recovery: "owned"}
	pid, err := system.Spawn(ctx, "agent-"+agent, actors.NewAgentActor(registration))
	if err != nil {
		t.Fatal(err)
	}
	runtimePID, err := system.Spawn(ctx, "runtime-"+agent, &inertRuntimeActor{})
	if err != nil {
		t.Fatal(err)
	}
	if err := system.NoSender().Tell(ctx, pid, &application.BindHostedPiRuntimeActor{PID: runtimePID}); err != nil {
		t.Fatal(err)
	}
	h := &bridgeHarness{system: system, pid: pid, agent: agent, session: "session-" + source, generation: "generation-" + source, principal: "hosted:" + source, handle: "handle-" + source}
	attached := h.ask(&application.AttachAgent{SessionID: h.session, GenerationID: h.generation, Principal: h.principal, RequestedCapabilities: registration.AllowedCapability, IssuedHandle: h.handle}).(*application.AttachResult)
	if !attached.Completed {
		t.Fatalf("attach failed: %#v", attached)
	}
	h.handle, h.fence = attached.Handle, attached.Fence
	connected := h.ask(&application.BridgeConnect{SessionID: h.session, GenerationID: h.generation, Principal: h.principal, AgentID: agent, Handle: h.handle, Fence: h.fence, RuntimeID: "runtime-" + agent, Incarnation: 1, PiSessionID: "pi-" + agent}).(*application.BridgeResult)
	if !connected.Accepted {
		t.Fatalf("bridge connect failed: %#v", connected)
	}
	return h
}

func (h *bridgeHarness) ask(message any) any {
	value, err := h.system.NoSender().Ask(context.Background(), h.pid, message, time.Second)
	if err != nil {
		panic(err)
	}
	return value
}

func (h *bridgeHarness) intent(mode application.BridgeMessageMode, source, dedupe, chain string, seq uint64) *application.BridgeIntent {
	capability := "send"
	if mode == application.BridgeMessageAsk {
		capability = "ask"
	}
	return &application.BridgeIntent{SessionID: h.session, GenerationID: h.generation, Principal: h.principal, Handle: h.handle, Fence: h.fence, SourceAgentID: source, TargetAgentID: h.agent, RequestID: "request-" + dedupe, RequiredCapability: capability, DedupeID: dedupe, ChainID: chain, Deadline: time.Now().Add(time.Minute), HopLimit: 8, SourceMutationSequence: seq, Mode: mode, Payload: []byte("reply with ok")}
}

func (h *bridgeHarness) poll() *application.BridgePollResult {
	return h.ask(&application.PollBridge{SessionID: h.session, GenerationID: h.generation, Principal: h.principal, Handle: h.handle, Fence: h.fence, MaxItems: 64}).(*application.BridgePollResult)
}

func (h *bridgeHarness) ack(delivery application.BridgeDelivery, answer string) *application.BridgeDeliveryAckResult {
	return h.ask(&application.BridgeDeliveryAck{SessionID: h.session, GenerationID: h.generation, Principal: h.principal, Handle: h.handle, Fence: h.fence, Sequence: delivery.Sequence, DedupeID: delivery.DedupeID, Delivered: true, Result: []byte(answer)}).(*application.BridgeDeliveryAckResult)
}

func TestCrossActorAsyncSendNotificationAtoB(t *testing.T) {
	b := newBridgeHarness(t, "cross-send", "bravo", "alpha")
	result := b.ask(b.intent(application.BridgeMessageTell, "alpha", "send-1", "chain-send-1", 1)).(*application.BridgeIntentResult)
	if !result.Accepted || result.AwaitingAck || result.Completed {
		t.Fatalf("tell was not accepted as async notification: %#v", result)
	}
	deliveries := b.poll().Deliveries
	if len(deliveries) != 1 || deliveries[0].Kind != application.BridgeDeliveryNotification || deliveries[0].SourceAgentID != "alpha" {
		t.Fatalf("typed notification missing: %#v", deliveries)
	}
}

func TestCrossActorAskAtoBReturnsCompletedAssistantAnswer(t *testing.T) {
	b := newBridgeHarness(t, "cross-ask-ab", "bravo", "alpha")
	completion := make(chan application.BridgeIntentResult, 1)
	intent := b.intent(application.BridgeMessageAsk, "alpha", "ask-1", "chain-ask-1", 1)
	intent.Completion = completion
	receipt := b.ask(intent).(*application.BridgeIntentResult)
	if !receipt.Accepted || !receipt.AwaitingAck {
		t.Fatalf("ask was not admitted as model task: %#v", receipt)
	}
	d := b.poll().Deliveries[0]
	if d.Kind != application.BridgeDeliveryPrompt {
		t.Fatalf("ask did not become prompt delivery: %#v", d)
	}
	if ack := b.ack(d, "assistant answer from B"); !ack.Accepted {
		t.Fatalf("ack failed: %#v", ack)
	}
	select {
	case got := <-completion:
		if !got.Completed || string(got.Result) != "assistant answer from B" {
			t.Fatalf("wrong completion: %#v", got)
		}
	case <-time.After(time.Second):
		t.Fatal("ask completion timed out")
	}
}

func TestCrossActorAskBtoA(t *testing.T) {
	a := newBridgeHarness(t, "cross-ask-ba", "alpha", "bravo")
	completion := make(chan application.BridgeIntentResult, 1)
	intent := a.intent(application.BridgeMessageAsk, "bravo", "ask-ba", "chain-ask-ba", 1)
	intent.Completion = completion
	if receipt := a.ask(intent).(*application.BridgeIntentResult); !receipt.Accepted || !receipt.AwaitingAck {
		t.Fatalf("B->A ask rejected: %#v", receipt)
	}
	d := a.poll().Deliveries[0]
	if ack := a.ack(d, "assistant answer from A"); !ack.Accepted {
		t.Fatalf("ack failed: %#v", ack)
	}
	select {
	case got := <-completion:
		if string(got.Result) != "assistant answer from A" {
			t.Fatalf("wrong answer: %#v", got)
		}
	case <-time.After(time.Second):
		t.Fatal("completion timed out")
	}
}

func TestCrossActorTwoConcurrentIndependentAsks(t *testing.T) {
	a := newBridgeHarness(t, "cross-concurrent-a", "alpha", "bravo")
	b := newBridgeHarness(t, "cross-concurrent-b", "bravo", "alpha")
	ca, cb := make(chan application.BridgeIntentResult, 1), make(chan application.BridgeIntentResult, 1)
	ia := a.intent(application.BridgeMessageAsk, "bravo", "ask-a", "chain-a", 1)
	ia.Completion = ca
	ib := b.intent(application.BridgeMessageAsk, "alpha", "ask-b", "chain-b", 1)
	ib.Completion = cb
	if r := a.ask(ia).(*application.BridgeIntentResult); !r.Accepted {
		t.Fatalf("A ask rejected: %#v", r)
	}
	if r := b.ask(ib).(*application.BridgeIntentResult); !r.Accepted {
		t.Fatalf("B ask rejected: %#v", r)
	}
	a.ack(a.poll().Deliveries[0], "A done")
	b.ack(b.poll().Deliveries[0], "B done")
	select {
	case <-ca:
	case <-time.After(time.Second):
		t.Fatal("A completion timed out")
	}
	select {
	case <-cb:
	case <-time.After(time.Second):
		t.Fatal("B completion timed out")
	}
}

func TestCrossActorReconnectResponseRecovery(t *testing.T) {
	b := newBridgeHarness(t, "cross-reconnect", "bravo", "alpha")
	first := make(chan application.BridgeIntentResult, 1)
	intent := b.intent(application.BridgeMessageAsk, "alpha", "ask-reconnect", "chain-reconnect", 1)
	intent.Completion = first
	if r := b.ask(intent).(*application.BridgeIntentResult); !r.Accepted {
		t.Fatalf("initial ask rejected: %#v", r)
	}
	second := make(chan application.BridgeIntentResult, 1)
	replay := b.intent(application.BridgeMessageAsk, "alpha", "ask-reconnect", "chain-reconnect", 1)
	replay.Completion = second
	if r := b.ask(replay).(*application.BridgeIntentResult); !r.Accepted || !r.AwaitingAck {
		t.Fatalf("replayed ask did not recover pending response: %#v", r)
	}
	b.ack(b.poll().Deliveries[0], "recovered answer")
	select {
	case got := <-second:
		if string(got.Result) != "recovered answer" {
			t.Fatalf("wrong recovered answer: %#v", got)
		}
	case <-time.After(time.Second):
		t.Fatal("recovered completion timed out")
	}
}

func TestCrossActorChainHopLoopRejection(t *testing.T) {
	b := newBridgeHarness(t, "cross-loop", "bravo", "alpha")
	zeroHop := b.intent(application.BridgeMessageAsk, "alpha", "ask-hop", "chain-hop", 1)
	zeroHop.HopLimit = 0
	if r := b.ask(zeroHop).(*application.BridgeIntentResult); r.Accepted {
		t.Fatalf("zero-hop loop was accepted: %#v", r)
	}
	first := b.intent(application.BridgeMessageAsk, "alpha", "ask-loop-1", "chain-loop", 1)
	if r := b.ask(first).(*application.BridgeIntentResult); !r.Accepted {
		t.Fatalf("first chain rejected: %#v", r)
	}
	repeated := b.intent(application.BridgeMessageAsk, "alpha", "ask-loop-2", "chain-loop", 2)
	if r := b.ask(repeated).(*application.BridgeIntentResult); r.Accepted {
		t.Fatalf("repeated chain was accepted: %#v", r)
	}
}

func TestCrossActorRestartReconciliationRetainsPendingAsk(t *testing.T) {
	b := newBridgeHarness(t, "cross-restart", "bravo", "alpha")
	completion := make(chan application.BridgeIntentResult, 1)
	intent := b.intent(application.BridgeMessageAsk, "alpha", "ask-restart", "chain-restart", 1)
	intent.Completion = completion
	if r := b.ask(intent).(*application.BridgeIntentResult); !r.Accepted {
		t.Fatalf("ask rejected: %#v", r)
	}
	if deliveries := b.poll().Deliveries; len(deliveries) != 1 || deliveries[0].Kind != application.BridgeDeliveryPrompt {
		t.Fatalf("pending ask not retained before restart: %#v", deliveries)
	}
	// Replaying the exact source mutation after a client reconnect models restart
	// reconciliation from retained actor state and must recover the same pending ask.
	recovered := make(chan application.BridgeIntentResult, 1)
	replay := b.intent(application.BridgeMessageAsk, "alpha", "ask-restart", "chain-restart", 1)
	replay.Completion = recovered
	if r := b.ask(replay).(*application.BridgeIntentResult); !r.Accepted || !r.AwaitingAck {
		t.Fatalf("reconciled replay rejected: %#v", r)
	}
	b.ack(b.poll().Deliveries[0], "after restart")
	select {
	case got := <-recovered:
		if string(got.Result) != "after restart" {
			t.Fatalf("wrong answer: %#v", got)
		}
	case <-time.After(time.Second):
		t.Fatal("reconciled completion timed out")
	}
}
