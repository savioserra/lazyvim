import type { CommunicationView } from "../../hosted-pi-bridge/communication-ui.ts";
import type { ConversationCard } from "./types.ts";

export function legacyCommunicationToCard(view: Readonly<CommunicationView>): ConversationCard {
  return {
    key: view.key,
    direction: view.direction,
    intent: view.intent,
    state: view.state,
    peerDisplayName: view.peerDisplayName,
    peerRole: view.peerRole,
    body: view.body,
    reply: view.reply,
    durationMillis: view.durationMillis,
  };
}

export function legacyLineToCard(key: string, line: string): ConversationCard {
  return { key, direction: "outgoing", intent: "failure", state: "failed", peerDisplayName: "Unknown actor", peerRole: "", body: line };
}
