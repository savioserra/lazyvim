import { Box, Text, truncateToWidth } from "@earendil-works/pi-tui";
import { envelopeCard, envelopeFromLegacy, type ActorClientRenderEnvelope } from "../projections/render-envelope.ts";
import { renderPlainCard } from "../projections/layout.ts";
import type { ConversationCard } from "../projections/types.ts";

function cardColor(card: ConversationCard): string {
  if (card.state === "failed") return "toolErrorBg";
  if (card.state === "pending") return "toolPendingBg";
  if (card.direction === "incoming") return "customMessageBg";
  return "toolSuccessBg";
}

export function renderProjectionConversationCard(card: ConversationCard, theme: any) {
  return renderActorClientConversationEnvelope({ schemaVersion: 1, kind: "conversation-card", key: card.key, renderSnapshot: { card } }, theme);
}

export function renderActorClientConversationEnvelope(envelope: ActorClientRenderEnvelope | unknown, theme: any) {
  const card = envelopeCard(envelope) ?? envelopeCard(envelopeFromLegacy(envelope as any))!;
  return {
    invalidate() {},
    render(width: number) {
      const box = new Box(1, 1, (text: string) => theme.bg(cardColor(card), text));
      for (const line of themedLines(card, theme, Math.max(20, width - 4))) box.addChild(new Text(line, 0, 0));
      return box.render(width).map((line: string) => truncateToWidth(line, width));
    },
  };
}

function themedLines(card: ConversationCard, theme: any, width: number): string[] {
  const lines = renderPlainCard(card, width);
  return lines.map((line) => {
    if (/!|Couldn’t reach|retry available/.test(line)) return theme.fg("error", line);
    if (/↙|replied|✓/.test(line)) return theme.fg("success", line);
    if (/Waiting|◌/.test(line)) return theme.fg("warning", line);
    if (/Asked|↗/.test(line)) return safeFg(theme, "magenta", "accent", line);
    if (/Sent to|↑/.test(line)) return safeFg(theme, "blue", "toolTitle", line);
    if (/↓/.test(line)) return theme.fg("accent", line);
    return line;
  });
}

function safeFg(theme: any, preferred: string, fallback: string, line: string): string { try { return theme.fg(preferred, line); } catch { return theme.fg(fallback, line); } }
