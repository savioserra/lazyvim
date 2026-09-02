package service

import (
	"context"
	"os"
	"testing"
	"time"

	subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"
	"github.com/savioserra/lazyvim/services/subagents/internal/actors"
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	goakt "github.com/tochemey/goakt/v4/actor"
)

func terminalEnvelope(opened *subagentsv1.ClientSessionResponse, sequence uint64, requestID string, envelope *subagentsv1.Envelope) *subagentsv1.Envelope {
	envelope.ProtocolMajor, envelope.ProtocolMinor = 1, 1
	envelope.Sequence, envelope.RequestId, envelope.DeadlineUnixMillis = sequence, requestID, time.Now().Add(5*time.Second).UnixMilli()
	envelope.SessionId, envelope.GenerationId, envelope.CallerIdentity, envelope.SessionCredential = opened.SessionId, opened.GenerationId, opened.CallerIdentity, opened.SessionCredential
	return envelope
}

func attachTerminalSelf(t *testing.T, daemon *Service, opened *subagentsv1.ClientSessionResponse, sequence uint64) *subagentsv1.AttachResponse {
	t.Helper()
	response := daemon.dispatch(terminalEnvelope(opened, sequence, "attach-self", &subagentsv1.Envelope{Payload: &subagentsv1.Envelope_AttachRequest{AttachRequest: &subagentsv1.AttachRequest{AgentId: opened.CallerIdentity, RequestedCapabilities: []string{"observe", "send", "ask", "prompt"}}}})).GetAttachResponse()
	if response == nil || response.AgentHandle == "" {
		t.Fatalf("terminal self attach failed: %#v", response)
	}
	return response
}

func resolveTerminalPID(t *testing.T, daemon *Service, agentID string) *application.AgentControlPID {
	t.Helper()
	value, err := daemon.system.NoSender().Ask(context.Background(), daemon.agentRegistry, &application.ResolveAgentControl{AgentID: agentID}, 3*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	resolved := value.(*application.AgentControlPID)
	if !resolved.Found || resolved.PID == nil {
		t.Fatalf("terminal actor %q unavailable", agentID)
	}
	return resolved
}

func pollRegularDelivery(t *testing.T, daemon *Service, opened *subagentsv1.ClientSessionResponse, attached *subagentsv1.AttachResponse) application.BridgeDelivery {
	t.Helper()
	target := resolveTerminalPID(t, daemon, opened.CallerIdentity)
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		value, err := daemon.system.NoSender().Ask(context.Background(), target.PID, &application.PollBridge{SessionID: opened.SessionId, GenerationID: opened.GenerationId, Principal: opened.CallerIdentity, Handle: attached.AgentHandle, Fence: attached.Fence, MaxItems: 64}, time.Second)
		if err == nil {
			poll := value.(*application.BridgePollResult)
			if len(poll.Deliveries) > 0 {
				return poll.Deliveries[0]
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("regular delivery did not become pollable")
	return application.BridgeDelivery{}
}

func regularAckRequest(delivery application.BridgeDelivery, delivered bool, reason string) *subagentsv1.BridgeDeliveryAckRequest {
	return &subagentsv1.BridgeDeliveryAckRequest{AgentId: delivery.TargetAgentID, Sequence: delivery.Sequence, DedupeId: delivery.DedupeID, Delivered: delivered, Reason: reason, Kind: application.BridgeDeliveryKindLabel(delivery.Kind), SourceScope: delivery.SourceScope, CompletionKey: delivery.CompletionKey}
}

func sendRegularTaskUntilAdmitted(t *testing.T, daemon *Service, source *goakt.PID, target *application.AgentControlPID, message application.SendActorTask) application.BridgeIntentResult {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		receipt := make(chan application.BridgeIntentResult, 1)
		message.TargetPID, message.Receipt = target.PID, receipt
		if err := daemon.system.NoSender().Tell(context.Background(), source, &message); err != nil {
			t.Fatal(err)
		}
		result := <-receipt
		if result.Accepted {
			return result
		}
		if result.Reason != "durable persistence is busy" || time.Now().After(deadline) {
			t.Fatalf("regular task admission failed: %#v", result)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestRegularPromptRestartRetiresAbandonedExecutorAndUnblocksLaterWork(t *testing.T) {
	root := t.TempDir()
	_ = os.Chmod(root, 0o700)
	daemon, stop := terminalIdentityHarnessAtRoot(t, root)
	defer func() { stop() }()
	opened := terminalIdentityOpen(t, daemon, "restart-regular")
	attached := attachTerminalSelf(t, daemon, opened, 2)
	target := resolveTerminalPID(t, daemon, opened.CallerIdentity)

	binding := application.InactiveHostedPiRuntimeBinding()
	source, err := daemon.system.Spawn(context.Background(), "restart-regular-source", actors.NewAgentActor(&application.RegisterAgent{AgentID: "restart-regular-source", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "restart-regular-source"}, HostedPiRuntime: binding, AllowedCapability: []string{"observe", "send"}, Retention: "bounded", Recovery: "terminal-reattach"}))
	if err != nil {
		t.Fatal(err)
	}
	receipt := make(chan application.BridgeIntentResult, 1)
	if err := daemon.system.NoSender().Tell(context.Background(), source, &application.SendActorTask{TargetPID: target.PID, TargetPeer: application.CommunicationPeer{StableID: opened.CallerIdentity}, RequestID: "restart-prompt-request", DedupeID: "restart-prompt-dedupe", ChainID: "restart-parent-chain", RequiredCapability: "ask", SourceMutationSequence: 1, Deadline: time.Now().Add(time.Hour), HopLimit: 8, Mode: application.BridgeMessageAsk, Payload: []byte("prompt injected by prior executor"), Receipt: receipt}); err != nil {
		t.Fatal(err)
	}
	if result := <-receipt; !result.Accepted || !result.AwaitingAck {
		t.Fatalf("regular prompt admission failed: %#v", result)
	}
	original := pollRegularDelivery(t, daemon, opened, attached)
	if original.Kind != application.BridgeDeliveryPrompt || original.DeliveryBackend != "regular" {
		t.Fatalf("regular prompt identity missing: %#v", original)
	}

	// Simulate process loss after the local injected marker was durable but
	// before any model settlement or ACK. The daemon and actor are reincarnated
	// from the same durable state directory.
	stop()
	daemon, stop = terminalIdentityHarnessAtRoot(t, root)
	reopened := terminalIdentityOpen(t, daemon, "restart-regular")
	fresh := attachTerminalSelf(t, daemon, reopened, 2)
	replayed := pollRegularDelivery(t, daemon, reopened, fresh)
	if replayed.Sequence != original.Sequence || replayed.DedupeID != original.DedupeID || replayed.SourceScope != original.SourceScope || replayed.CompletionKey != original.CompletionKey {
		t.Fatalf("restart changed immutable delivery identity: before=%#v after=%#v", original, replayed)
	}

	stale := daemon.dispatch(terminalEnvelope(reopened, 3, "stale-ack", &subagentsv1.Envelope{Payload: &subagentsv1.Envelope_BridgeDeliveryAckRequest{BridgeDeliveryAckRequest: regularAckRequest(replayed, false, "terminal executor restarted before prompt settlement")}}))
	if response := stale.GetBridgeDeliveryAckResponse(); response == nil || response.Accepted {
		t.Fatalf("unfenced abandoned ACK was accepted: %#v", response)
	}

	ackEnvelope := terminalEnvelope(reopened, 4, "fresh-ack", &subagentsv1.Envelope{Payload: &subagentsv1.Envelope_BridgeDeliveryAckRequest{BridgeDeliveryAckRequest: regularAckRequest(replayed, false, "terminal executor restarted before prompt settlement")}})
	ackEnvelope.AgentHandle, ackEnvelope.AgentFence = fresh.AgentHandle, fresh.Fence
	var accepted *subagentsv1.BridgeDeliveryAckResponse
	for retry := 0; retry < 8; retry++ {
		ackEnvelope.Sequence++
		ackEnvelope.RequestId = "fresh-ack-" + time.Now().String()
		accepted = daemon.dispatch(ackEnvelope).GetBridgeDeliveryAckResponse()
		if accepted != nil && accepted.Accepted {
			break
		}
		if accepted == nil || accepted.RejectionCode != "persistence_busy" {
			t.Fatalf("fresh abandoned ACK rejected non-transiently: %#v", accepted)
		}
		time.Sleep(25 * time.Millisecond)
	}
	if accepted == nil || !accepted.Accepted || accepted.Cursor != replayed.Sequence {
		t.Fatalf("abandoned prompt did not retire contiguously: %#v", accepted)
	}

	// Later Tell and Ask mutations in one parent chain must now progress in
	// order instead of entering stale-credit churn behind the retired prompt.
	target = resolveTerminalPID(t, daemon, reopened.CallerIdentity)
	followSource, err := daemon.system.Spawn(context.Background(), "restart-regular-follow-source", actors.NewAgentActor(&application.RegisterAgent{AgentID: "restart-regular-follow-source", AuthorityBinding: application.AuthorityBinding{Kind: application.AuthorityBindingPhaseOneObservedUpstream, ObservedUpstreamRunID: "restart-regular-follow-source"}, HostedPiRuntime: application.InactiveHostedPiRuntimeBinding(), AllowedCapability: []string{"observe", "send"}, Retention: "bounded", Recovery: "terminal-reattach"}))
	if err != nil {
		t.Fatal(err)
	}
	common := application.SendActorTask{TargetPeer: application.CommunicationPeer{StableID: reopened.CallerIdentity}, RequiredCapability: "send", ChainID: "later-parent-chain", Deadline: time.Now().Add(time.Minute), HopLimit: 8}
	tell := common
	tell.RequestID, tell.DedupeID, tell.SourceMutationSequence, tell.Mode, tell.Payload = "later-tell-request", "later-tell-dedupe", 1, application.BridgeMessageTell, []byte("later tell")
	sendRegularTaskUntilAdmitted(t, daemon, followSource, target, tell)
	taskAsk := common
	taskAsk.RequestID, taskAsk.DedupeID, taskAsk.SourceMutationSequence, taskAsk.Mode, taskAsk.Payload = "later-ask-request", "later-ask-dedupe", 2, application.BridgeMessageAsk, []byte("later ask")
	sendRegularTaskUntilAdmitted(t, daemon, followSource, target, taskAsk)

	var later []application.BridgeDelivery
	laterDeadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(laterDeadline) {
		value, pollErr := daemon.system.NoSender().Ask(context.Background(), target.PID, &application.PollBridge{SessionID: reopened.SessionId, GenerationID: reopened.GenerationId, Principal: reopened.CallerIdentity, Handle: fresh.AgentHandle, Fence: fresh.Fence, AfterSequence: replayed.Sequence, MaxItems: 64}, time.Second)
		if pollErr == nil {
			later = value.(*application.BridgePollResult).Deliveries
			if len(later) == 2 {
				break
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	if len(later) != 2 || later[0].Kind != application.BridgeDeliveryNotification || later[1].Kind != application.BridgeDeliveryPrompt {
		t.Fatalf("later same-chain Tell/Ask did not converge: %#v", later)
	}
	for index, delivery := range later {
		request := regularAckRequest(delivery, true, "")
		if delivery.Kind == application.BridgeDeliveryPrompt {
			request.BoundedResult = []byte("later answer")
		}
		var response *subagentsv1.BridgeDeliveryAckResponse
		for retry := 0; retry < 8; retry++ {
			envelope := terminalEnvelope(reopened, uint64(20+index*10+retry), "later-ack", &subagentsv1.Envelope{Payload: &subagentsv1.Envelope_BridgeDeliveryAckRequest{BridgeDeliveryAckRequest: request}})
			envelope.AgentHandle, envelope.AgentFence = fresh.AgentHandle, fresh.Fence
			response = daemon.dispatch(envelope).GetBridgeDeliveryAckResponse()
			if response != nil && response.Accepted {
				break
			}
			if response == nil || response.RejectionCode != "persistence_busy" {
				t.Fatalf("later delivery ACK failed: %#v", response)
			}
			time.Sleep(25 * time.Millisecond)
		}
		if response == nil || !response.Accepted {
			t.Fatalf("later delivery ACK did not converge: %#v", response)
		}
	}

	// A second restart must not replay the retired prompt or later work.
	stop()
	daemon, stop = terminalIdentityHarnessAtRoot(t, root)
	reopened = terminalIdentityOpen(t, daemon, "restart-regular")
	fresh = attachTerminalSelf(t, daemon, reopened, 2)
	target = resolveTerminalPID(t, daemon, reopened.CallerIdentity)
	value, err := daemon.system.NoSender().Ask(context.Background(), target.PID, &application.PollBridge{SessionID: reopened.SessionId, GenerationID: reopened.GenerationId, Principal: reopened.CallerIdentity, Handle: fresh.AgentHandle, Fence: fresh.Fence, MaxItems: 64}, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if poll := value.(*application.BridgePollResult); len(poll.Deliveries) != 0 {
		t.Fatalf("retired prompt replayed after second restart: %#v", poll)
	}
}
