package service

import (
	"context"
	"errors"

	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

func (a *hostedPlacementAuthority) remoteAttach(ctx context.Context, message *application.RemoteAttachAgent) *application.AttachResult {
	pid, err := a.localAgentPID(ctx, message.AgentID)
	if err != nil {
		return &application.AttachResult{Reason: err.Error()}
	}
	result := make(chan application.AttachResult, 1)
	local := &application.AttachAgent{SessionID: message.SessionID, GenerationID: message.GenerationID, Principal: message.Principal, AgentID: message.AgentID, RequestedCapabilities: message.RequestedCapabilities, IssuedHandle: message.IssuedHandle, Result: result}
	if err := a.service.system.NoSender().Tell(ctx, pid, local); err != nil {
		return &application.AttachResult{Reason: err.Error()}
	}
	select {
	case value := <-result:
		return &value
	case <-ctx.Done():
		return &application.AttachResult{Reason: ctx.Err().Error()}
	}
}

// remoteBridgeIntent is the synchronous correlation boundary for remote prompt
// and task-lifecycle bridge intents: it forwards to the local target agent and
// holds the remote reply open until the acknowledged terminal or deadline.
// Actor messages do not use this path: they follow the credit/task protocol
// addressed directly to the agent actor.
func (a *hostedPlacementAuthority) remoteBridgeIntent(ctx context.Context, message *application.RemoteBridgeIntent) *application.BridgeIntentResult {
	pid, err := a.localAgentPID(ctx, message.TargetAgentID)
	if err != nil {
		return &application.BridgeIntentResult{Reason: err.Error()}
	}
	receipt := make(chan application.BridgeIntentResult, 1)
	completion := make(chan application.BridgeIntentResult, 1)
	intent := &application.BridgeIntent{SessionID: message.SessionID, GenerationID: message.GenerationID, Principal: message.Principal, Handle: message.Handle, SourceAgentID: message.SourceAgentID, TargetAgentID: message.TargetAgentID, RequestID: message.RequestID, RequiredCapability: message.RequiredCapability, DedupeID: message.DedupeID, ChainID: message.ChainID, Fence: message.Fence, SourceMutationSequence: message.SourceMutationSequence, Deadline: message.Deadline, HopLimit: message.HopLimit, Mode: message.Mode, Payload: message.Payload, Receipt: receipt, Completion: completion}
	if err := a.service.system.NoSender().Tell(ctx, pid, intent); err != nil {
		return &application.BridgeIntentResult{Reason: err.Error()}
	}
	select {
	case result := <-receipt:
		if result.Accepted && result.AwaitingAck && message.RequiredCapability == "prompt" {
			select {
			case completed := <-completion:
				return &completed
			case <-ctx.Done():
				return &application.BridgeIntentResult{Accepted: true, Reason: ctx.Err().Error()}
			}
		}
		return &result
	case <-ctx.Done():
		return &application.BridgeIntentResult{Reason: ctx.Err().Error()}
	}
}

// remoteResolveAgentActor answers a remote node's request for the concrete
// agent actor name so cross-node delivery can address the agent actor directly
// and preserve the original sender identity across remoting.
func (a *hostedPlacementAuthority) remoteResolveAgentActor(ctx context.Context, message *application.ResolveAgentActor) *application.AgentActorRef {
	pid, err := a.localAgentPID(ctx, message.AgentID)
	if err != nil || pid == nil {
		return &application.AgentActorRef{AgentID: message.AgentID, Reason: "agent actor unavailable"}
	}
	return &application.AgentActorRef{AgentID: message.AgentID, ActorName: pid.Name(), Found: true}
}

func (a *hostedPlacementAuthority) localAgentPID(ctx context.Context, agentID string) (*actor.PID, error) {
	value, err := a.service.system.NoSender().Ask(ctx, a.service.agentRegistry, &application.ResolveAgentControl{AgentID: agentID}, requestTimeout)
	if err != nil {
		return nil, err
	}
	control, ok := value.(*application.AgentControlPID)
	if !ok || !control.Found || control.PID == nil {
		return nil, errors.New("agent unavailable")
	}
	return control.PID, nil
}
