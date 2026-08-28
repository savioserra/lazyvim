package actors

import (
	"github.com/savioserra/lazyvim/services/subagents/internal/application"
	"github.com/tochemey/goakt/v4/actor"
)

func (a *AgentActor) remoteAttach(ctx *actor.ReceiveContext, message *application.RemoteAttachAgent) {
	local := &application.AttachAgent{SessionID: message.SessionID, GenerationID: message.GenerationID, Principal: message.Principal, AgentID: message.AgentID, RequestedCapabilities: message.RequestedCapabilities, IssuedHandle: message.IssuedHandle}
	if a.isRevoked(local.SessionID, local.GenerationID) {
		respondAttach(ctx, nil, &application.AttachResult{Reason: "session generation revoked"})
		return
	}
	capabilities := make(map[string]struct{}, len(local.RequestedCapabilities))
	for _, capability := range local.RequestedCapabilities {
		if _, ok := a.allowed[capability]; !ok {
			respondAttach(ctx, nil, &application.AttachResult{Reason: "capability denied"})
			return
		}
		capabilities[capability] = struct{}{}
	}
	if a.durablePending != nil || a.durableFailed != nil {
		respondAttach(ctx, nil, &application.AttachResult{Reason: "durable persistence is busy"})
		return
	}
	old := a.durableState()
	key := generationKey(local.SessionID, local.GenerationID)
	if current, exists := a.attachments[key]; exists {
		a.pruneRevokedMutationScope(local.SessionID, local.GenerationID, current.principal, current.fence)
	}
	a.fence++
	a.attachments[key] = attachment{principal: local.Principal, handle: local.IssuedHandle, fence: a.fence, capabilities: capabilities}
	a.revision++
	result := application.AttachResult{Completed: true, Handle: local.IssuedHandle, Fence: a.fence}
	if a.beginDurablePersist(ctx, &pendingDurableReceipt{old: old, attach: &result}) {
		return
	}
	respondAttach(ctx, nil, &result)
}
