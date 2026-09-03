import type { ConversationCard, ExecutorRef, ExecutorState, PendingInteraction, PeerMetadata } from "./types.ts";
export type ActorClientProjectionEvent =
  | { type: "SESSION.START"; generation: number }
  | { type: "SESSION.RESET"; generation: number }
  | { type: "TRANSPORT.CONNECTING" | "TRANSPORT.AUTHENTICATING" | "TRANSPORT.SUBSCRIBING_ROSTER" | "TRANSPORT.CONNECTED" | "TRANSPORT.RECONNECTING" | "TRANSPORT.CLOSING" | "TRANSPORT.DISCONNECTED" }
  | { type: "TRANSPORT.DEGRADED"; reason: string }
  | { type: "ROSTER.FRAME"; frame: any }
  | { type: "TASK.ADMITTED"; pending: PendingInteraction }
  | { type: "TASK.BACKPRESSURED"; key: string; target?: PeerMetadata | string; reason: string }
  | { type: "TASK.COMPLETED"; key: string; reply: string; completed: boolean; reason?: string; source?: PeerMetadata; target?: PeerMetadata | string; kind?: string; requestId?: string; dedupeId?: string; chainId?: string; sourceMutationSequence?: string }
  | { type: "CLIENT.DRAFT.SET"; draft: string }
  | { type: "USER_TURN.ADMISSION.REQUESTED"; proposedTurnId: string; actorEpoch: string; baseTranscriptSeq: number; idempotencyKey: string }
  | { type: "USER_TURN.ADMISSION.DECISION"; proposedTurnId: string; actorEpoch: string; decision: "admit" | "defer" | "reject"; admissionToken?: string; reason?: string }
  | { type: "USER_TURN.SUBMITTED"; proposedTurnId: string; turnId: string; actorEpoch: string; admissionToken: string; idempotencyKey: string }
  | { type: "ACTOR.SNAPSHOT"; actorEpoch: string; transcriptSeq: number; eventSeq: number; executor?: { ref: ExecutorRef; state: ExecutorState; lifecycleSeq: number }; pendingPresentation?: { presentationId: string; turnId: string; transcriptSeq: number; actorEpoch: string; requirement: string }[]; availableContinuations?: { continuationId: string; turnId: string; label: string; mode: "suggested" | "recommended" | "required_ack"; actorEpoch: string; eventSeq: number }[]; availableIntrospections?: { introspectionId: string; scope: "last_turn" | "executor_state" | "transcript_window"; privacyNotice: string; actorEpoch: string; eventSeq: number }[] }
  | { type: "ACTOR.REINCARNATION"; oldActorEpoch?: string; newActorEpoch: string; recovery: "lossless" | "snapshot_only" | "transcript_replay_required" | "state_lost"; executorRecovery?: "same_generation_valid" | "new_generation_issued" | "executor_state_unknown" | "executor_absent"; currentExecutor?: { ref: ExecutorRef; state: ExecutorState; lifecycleSeq: number } }
  | { type: "EXECUTOR.LIFECYCLE"; executor: ExecutorRef; state: ExecutorState; lifecycleSeq: number; turnId?: string; reason?: string }
  | { type: "EXECUTOR.COMMAND.REQUESTED"; executor: ExecutorRef; command: "request_stop" | "request_abort"; idempotencyKey: string }
  | { type: "EXECUTOR.COMMAND.RESULT"; executor: ExecutorRef; idempotencyKey: string; status: "accepted" | "rejected" | "duplicate"; rejectionReason?: "stale_executor_generation" | "stale_actor_epoch" | "executor_not_found" | "command_not_allowed" | "actor_reincarnated" }
  | { type: "PRESENTATION.REQUIRED"; presentationId: string; turnId: string; transcriptSeq: number; actorEpoch: string; eventSeq: number; requirement: string }
  | { type: "PRESENTATION.RENDERED"; presentationId: string; turnId: string; transcriptSeq: number; actorEpoch: string; clientSessionId: string; renderedAt: string; visibleRegion?: { firstSeq: number; lastSeq: number } }
  | { type: "CONTINUATION.AVAILABLE"; continuationId: string; turnId: string; label: string; mode: "suggested" | "recommended" | "required_ack"; actorEpoch: string; eventSeq: number }
  | { type: "INTROSPECTION.AVAILABLE"; introspectionId: string; scope: "last_turn" | "executor_state" | "transcript_window"; privacyNotice: string; actorEpoch: string; eventSeq: number }
  | { type: "DELIVERY.INCOMING.NOTE" | "DELIVERY.INCOMING.REQUEST"; key: string; source?: PeerMetadata; body: Uint8Array | string }
  | { type: "CONVERSATION.APPEND"; card: ConversationCard }
  | { type: "PRESENTATION.SUCCEEDED"; key: string; digest: string }
  | { type: "PRESENTATION.FAILED"; key: string; reason: string }
  | { type: "RESTORE.PENDING"; pending: PendingInteraction }
  | { type: "RESTORE.COMPLETION"; key: string; digest: string; requestId?: string }
  | { type: "VIEW.WIDTH"; width: number }
  | { type: "VIEW.THEME"; revision: number };
