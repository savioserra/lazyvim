import type { ConversationCard, PendingInteraction, PeerMetadata } from "./types.ts";
export type ActorClientProjectionEvent =
  | { type: "SESSION.START"; generation: number }
  | { type: "SESSION.RESET"; generation: number }
  | { type: "TRANSPORT.CONNECTING" | "TRANSPORT.AUTHENTICATING" | "TRANSPORT.SUBSCRIBING_ROSTER" | "TRANSPORT.CONNECTED" | "TRANSPORT.RECONNECTING" | "TRANSPORT.CLOSING" | "TRANSPORT.DISCONNECTED" }
  | { type: "TRANSPORT.DEGRADED"; reason: string }
  | { type: "ROSTER.FRAME"; frame: any }
  | { type: "TASK.ADMITTED"; pending: PendingInteraction }
  | { type: "TASK.BACKPRESSURED"; key: string; target?: PeerMetadata | string; reason: string }
  | { type: "TASK.COMPLETED"; key: string; reply: string; completed: boolean; reason?: string; source?: PeerMetadata; target?: PeerMetadata | string; kind?: string; requestId?: string; dedupeId?: string; chainId?: string; sourceMutationSequence?: string }
  | { type: "DELIVERY.INCOMING.NOTE" | "DELIVERY.INCOMING.REQUEST"; key: string; source?: PeerMetadata; body: Uint8Array | string }
  | { type: "CONVERSATION.APPEND"; card: ConversationCard }
  | { type: "PRESENTATION.SUCCEEDED"; key: string; digest: string }
  | { type: "PRESENTATION.FAILED"; key: string; reason: string }
  | { type: "RESTORE.PENDING"; pending: PendingInteraction }
  | { type: "RESTORE.COMPLETION"; key: string; digest: string }
  | { type: "VIEW.WIDTH"; width: number }
  | { type: "VIEW.THEME"; revision: number };
