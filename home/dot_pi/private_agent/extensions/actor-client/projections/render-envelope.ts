import type { CommunicationView } from "../../hosted-pi-bridge/communication-ui.ts";
import { legacyCommunicationToCard } from "./legacy.ts";
import type { ConversationCard, RenderSnapshot } from "./types.ts";

export const ACTOR_CLIENT_RENDER_ENVELOPE_VERSION = 1;
export type ActorClientRenderEnvelope = {
  schemaVersion: 1;
  kind: "conversation-card";
  key: string;
  renderSnapshot: { card: ConversationCard };
  legacy?: { line?: string; communicationView?: CommunicationView };
};

export function conversationEnvelope(card: ConversationCard, legacy?: { line?: string; communicationView?: CommunicationView }): ActorClientRenderEnvelope {
  return { schemaVersion: ACTOR_CLIENT_RENDER_ENVELOPE_VERSION, kind: "conversation-card", key: card.key, renderSnapshot: { card: { ...card } }, legacy };
}

export function envelopeFromLegacy(input: { key?: string; line?: string; view?: CommunicationView; communicationView?: CommunicationView }): ActorClientRenderEnvelope {
  const view = input.view ?? input.communicationView;
  const card = view ? legacyCommunicationToCard(view) : legacyCommunicationToCard({ key: input.key ?? "actor-client:legacy", direction: "outgoing", intent: "failure", state: "failed", peerDisplayName: "Unknown actor", peerRole: "", body: input.line ?? "actor communication unavailable" });
  return conversationEnvelope(card, { line: input.line, communicationView: view });
}

export function envelopeCard(value: unknown): ConversationCard | undefined {
  const envelope = value as Partial<ActorClientRenderEnvelope> | undefined;
  if (envelope?.schemaVersion === 1 && envelope.kind === "conversation-card" && envelope.renderSnapshot?.card?.key) return { ...envelope.renderSnapshot.card };
  return undefined;
}

export function snapshotEnvelope(snapshot: RenderSnapshot, key: string): ActorClientRenderEnvelope | undefined {
  const card = snapshot.cards.find((item) => item.key === key);
  return card ? conversationEnvelope(card) : undefined;
}
