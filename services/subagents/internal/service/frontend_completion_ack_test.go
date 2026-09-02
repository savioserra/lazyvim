package service

import subagentsv1 "github.com/savioserra/lazyvim/services/subagents/api/subagents/v1"

func frontendCompletionAck(frame *subagentsv1.Envelope) *subagentsv1.FrontendCompletionAckRequest {
	reply := frame.GetActorMessageReplyFrame()
	if reply == nil {
		return nil
	}
	return &subagentsv1.FrontendCompletionAckRequest{CompletionKey: reply.CompletionKey, FrameSequence: frame.Sequence, OriginalRequestId: reply.OriginalRequestId, DedupeId: reply.DedupeId, ChainId: reply.ChainId, SourceMutationSequence: reply.SourceMutationSequence}
}
