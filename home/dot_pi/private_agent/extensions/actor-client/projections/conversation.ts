import { digestPresentation, rememberCompletion } from "./dedupe.ts";
import { naturalRole, sanitizeText } from "./sanitize.ts";
import type { ConversationCard, PendingInteraction, PeerMetadata } from "./types.ts";

export function peerView(peer?: PeerMetadata | string): { displayName: string; role: string } {
  if (typeof peer === "string") return { displayName: sanitizeText(peer || "Unknown actor", 48), role: "" };
  return { displayName: sanitizeText(peer?.displayName ?? "Unknown actor", 48), role: naturalRole(peer?.role) ?? "" };
}

export function incomingCard(input: { key: string; source?: PeerMetadata; body: Uint8Array | string; request?: boolean }): ConversationCard {
  const peer = peerView(input.source);
  return { key: input.key, direction: "incoming", intent: input.request ? "request" : "note", state: input.request ? "pending" : "delivered", peerDisplayName: peer.displayName, peerRole: peer.role, body: sanitizeText(input.body, 480) };
}

export function outgoingCard(input: { key: string; target?: PeerMetadata | string; body: string; reply?: string; accepted: boolean; completed?: boolean; mode: "tell" | "ask"; reason?: string; durationMillis?: number }): ConversationCard {
  const peer = peerView(input.target);
  if (!input.accepted) return { key: input.key, direction: "outgoing", intent: "failure", state: "failed", peerDisplayName: peer.displayName, peerRole: peer.role, body: sanitizeText(input.reason || "The actor did not admit the message.", 480), durationMillis: input.durationMillis };
  if (input.mode === "ask") return { key: input.key, direction: "outgoing", intent: "request", state: input.completed === false ? "pending" : "replied", peerDisplayName: peer.displayName, peerRole: peer.role, body: sanitizeText(input.body, 480), reply: sanitizeText(input.reply, 480), durationMillis: input.durationMillis };
  return { key: input.key, direction: "outgoing", intent: "note", state: "delivered", peerDisplayName: peer.displayName, peerRole: peer.role, body: sanitizeText(input.body, 480), durationMillis: input.durationMillis };
}

export function completeAsk(input: { cards: Map<string, ConversationCard>; pending: Map<string, PendingInteraction>; completions: Map<string, string>; key: string; reply: string; completed: boolean; reason?: string; source?: PeerMetadata; target?: PeerMetadata | string; kind?: string; requestId?: string; dedupeId?: string; chainId?: string; sourceMutationSequence?: string }): { cards: Map<string, ConversationCard>; pending: Map<string, PendingInteraction>; completions: Map<string, string>; card: ConversationCard; digest: string; duplicate: boolean } {
  const pending = input.pending.get(input.key) ?? [...input.pending.values()].find((entry) => entry.requestId === input.requestId);
  const visibleKey = input.key;
  const card = outgoingCard({ key: visibleKey, target: input.target ?? pending?.targetPeer ?? pending?.target ?? "Unknown actor", body: pending?.prompt ?? `Ask request ${input.requestId ?? pending?.requestId ?? input.key}`, reply: input.reply, accepted: input.completed, completed: input.completed, mode: "ask", reason: input.reason });
  const digest = digestPresentation({ terminal: input.completed ? "replied" : "failed", reply: input.reply, reason: input.reason ?? "", requestId: input.requestId ?? pending?.requestId ?? "", dedupeId: input.dedupeId ?? pending?.dedupeId ?? "", chainId: input.chainId ?? pending?.chainId ?? "", sourceMutationSequence: input.sourceMutationSequence ?? pending?.sourceMutationSequence ?? "" });
  const completions = rememberCompletion(input.completions, input.key, digest);
  if (input.completions.get(input.key) === digest) return { cards: input.cards, pending: input.pending, completions, card, digest, duplicate: true };
  const nextCards = new Map(input.cards);
  nextCards.set(visibleKey, { ...card, terminalDigest: digest });
  const nextPending = new Map(input.pending);
  nextPending.delete(input.key);
  if (pending?.key) nextPending.delete(pending.key);
  return { cards: nextCards, pending: nextPending, completions, card, digest, duplicate: false };
}
