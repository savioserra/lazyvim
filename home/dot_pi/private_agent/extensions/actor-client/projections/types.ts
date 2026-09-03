export type ConnectionStatus = "disconnected" | "connecting" | "authenticating" | "subscribingRoster" | "connected" | "reconnecting" | "degraded" | "closing";
export type PeerMetadata = { stableId?: string; displayName: string; role?: string; authoritative: boolean };
export type ActorRosterItem = { agentId: string; displayName: string; role?: string; lifecycle: string; revision: bigint };
export type RosterProjection = { epoch: bigint; sequence: bigint; agents: Map<string, ActorRosterItem>; overflow: number; degradedReason?: string };
export type PendingInteraction = { key: string; requestId: string; dedupeId: string; chainId: string; sourceMutationSequence: string; source?: string; target?: string; kind: string; prompt: string; targetPeer?: PeerMetadata; hidden: true };
export type ConversationState = "pending" | "delivered" | "replied" | "failed";
export type ConversationIntent = "note" | "request" | "reply" | "control" | "failure";
export type ConversationCard = { key: string; direction: "incoming" | "outgoing"; intent: ConversationIntent; state: ConversationState; peerDisplayName: string; peerRole: string; body: string; reply?: string; durationMillis?: number; terminalDigest?: string };
export type RenderSnapshot = { connection: ConnectionStatus; statusLine?: string; pendingLine?: string; cards: ConversationCard[]; width: number; overflow: number; themeRevision: number; inputState?: UserTurnInputState; executorLine?: string; presentationAckLine?: string; continuationLine?: string; introspectionLine?: string };

export type ClientSemanticFamily = "Tell" | "Ask" | "UserTurn" | "SelfContinuation" | "Waiting" | "Blocked" | "Completion" | "PresentationAck" | "Introspection";
export const CLIENT_SEMANTIC_FAMILIES: readonly ClientSemanticFamily[] = Object.freeze(["Tell", "Ask", "UserTurn", "SelfContinuation", "Waiting", "Blocked", "Completion", "PresentationAck", "Introspection"] as const);

export type UserTurnInputState = "admission_required" | "admission_pending" | "admitted" | "blocked" | "executing" | "replay_required" | "state_lost";
export type AdmissionDecision = "admit" | "defer" | "reject";
export type TurnAdmissionProjection = { proposedTurnId?: string; state: UserTurnInputState; actorEpoch?: string; baseTranscriptSeq?: number; admissionToken?: string; idempotencyKey?: string; reason?: string };

export type ExecutorState = "idle" | "starting" | "running" | "waiting_for_presentation_ack" | "waiting_for_client_input" | "continuing" | "introspecting" | "stopping" | "stopped" | "failed";
export type ExecutorRef = { executorId: string; executorGeneration: string; actorEpoch: string };
export type ExecutorProjection = { current?: ExecutorRef; state?: ExecutorState; lifecycleSeq?: number; seenLifecycleEvents: Set<string>; pendingCommands: Map<string, { executor: ExecutorRef; command: "request_stop" | "request_abort"; idempotencyKey: string }> };
export type PresentationAckPayload = { type: "client.presentation.ack"; presentationId: string; turnId: string; transcriptSeq: number; actorEpoch: string; clientSessionId: string; renderedAt: string; visibleRegion?: { firstSeq: number; lastSeq: number } };
export type AffordanceProjection = { continuations: Map<string, { turnId: string; label: string; mode: "suggested" | "recommended" | "required_ack"; actorEpoch: string; eventSeq: number }>; introspections: Map<string, { scope: "last_turn" | "executor_state" | "transcript_window"; privacyNotice: string; actorEpoch: string; eventSeq: number }> };

export type ProjectionContext = { sessionGeneration: number; connection: ConnectionStatus; actorEpoch?: string; transcriptSeq: number; eventSeq: number; replayAuthority: boolean; draft: string; turnAdmission: TurnAdmissionProjection; executor: ExecutorProjection; affordances: AffordanceProjection; pendingPresentation: Map<string, { presentationId: string; turnId: string; transcriptSeq: number; actorEpoch: string; requirement: string }>; acknowledgedPresentations: Set<string>; presentationAckOutbox: PresentationAckPayload[]; roster: RosterProjection; pending: Map<string, PendingInteraction>; cards: Map<string, ConversationCard>; completions: Map<string, string>; presented: Set<string>; snapshot: RenderSnapshot; maxCards: number };
export type EffectIntent = { type: "PRESENT_COMPLETION"; key: string; digest: string; card: ConversationCard } | { type: "REQUEST_ROSTER_REPLAY"; epoch: bigint; sequence: bigint } | { type: "SET_STATUS"; key: string; value?: string };
