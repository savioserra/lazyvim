package service

import "github.com/savioserra/lazyvim/services/subagents/internal/application"

func remoteBridgeIntent(message *application.BridgeIntent) *application.RemoteBridgeIntent {
	return &application.RemoteBridgeIntent{SessionID: message.SessionID, GenerationID: message.GenerationID, Principal: message.Principal, Handle: message.Handle, SourceAgentID: message.SourceAgentID, TargetAgentID: message.TargetAgentID, RequestID: message.RequestID, RequiredCapability: message.RequiredCapability, DedupeID: message.DedupeID, ChainID: message.ChainID, Fence: message.Fence, SourceMutationSequence: message.SourceMutationSequence, Deadline: message.Deadline, HopLimit: message.HopLimit, Mode: message.Mode, Payload: message.Payload}
}
