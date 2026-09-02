import { Box, Text } from "@earendil-works/pi-tui";
import { renderPlainCard } from "../projections/layout.ts";
import type { ConversationCard } from "../projections/types.ts";

export function renderProjectionConversationCard(card: ConversationCard, theme: any) {
  const bg = card.direction === "incoming" ? "customMessageBg" : card.state === "failed" ? "toolErrorBg" : card.state === "pending" ? "toolPendingBg" : "toolSuccessBg";
  const box = new Box(1, 1, (text: string) => theme.bg(bg, text));
  for (const line of renderPlainCard(card, 100)) box.addChild(new Text(line, 0, 0));
  return box;
}
