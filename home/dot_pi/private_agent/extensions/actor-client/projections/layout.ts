import type { ConversationCard, ProjectionContext, RenderSnapshot } from "./types.ts";
import { renderRosterStatus } from "./roster.ts";

export function projectSnapshot(context: ProjectionContext, width = context.snapshot.width, themeRevision = context.snapshot.themeRevision): RenderSnapshot {
  const roster = renderRosterStatus(context.connection, context.roster, Math.max(24, Math.min(width, 120)));
  const pending = context.pending.size ? `◌ actor asks ${context.pending.size} pending` : undefined;
  const cards = [...context.cards.values()].slice(-context.maxCards);
  return { connection: context.connection, statusLine: roster.line, pendingLine: pending, cards, width, overflow: roster.overflow + Math.max(0, context.cards.size - cards.length), themeRevision };
}

export function wrapPlain(text: string, width: number): string[] {
  const limit = Math.max(1, width);
  const output: string[] = [];
  for (const paragraph of String(text).split("\n")) {
    let line = paragraph.trimEnd();
    if (!line) { output.push(""); continue; }
    while (line.length > limit) {
      let cut = line.slice(0, limit).lastIndexOf(" ");
      if (cut < Math.floor(limit / 2)) cut = limit;
      output.push(line.slice(0, cut).trimEnd());
      line = line.slice(cut).trimStart();
    }
    output.push(line);
  }
  return output;
}

export function renderPlainCard(card: ConversationCard, width: number): string[] {
  const icon = card.state === "failed" ? "!" : card.direction === "incoming" ? "↓" : card.intent === "request" ? "↗" : "↑";
  const role = card.peerRole ? ` · ${card.peerRole}` : "";
  const title = card.state === "failed" ? `Couldn’t reach ${card.peerDisplayName}${role}` : card.direction === "incoming" && card.intent === "request" ? `${card.peerDisplayName}${role} asked you` : card.direction === "incoming" ? `${card.peerDisplayName}${role} sent a note` : card.intent === "request" ? `Asked ${card.peerDisplayName}${role}` : `Sent to ${card.peerDisplayName}${role}`;
  const narrow = width < 50;
  const inner = Math.max(8, narrow ? width - 2 : width - 4);
  const lines = [`${icon} ${title}`, ...wrapPlain(card.body, inner)];
  if (card.reply) lines.push("", `↙ ${card.peerDisplayName} replied`, ...wrapPlain(card.reply, inner));
  lines.push(card.state === "failed" ? "retry available" : card.state === "pending" ? `◌ Waiting for ${card.peerDisplayName}…` : card.state === "replied" ? "✓ replied" : "✓ delivered");
  if (narrow) return lines.map((line) => line.slice(0, width));
  return ["╭─ " + lines[0], ...lines.slice(1).map((line) => `│ ${line}`.slice(0, width)), "╰─"].map((line) => line.slice(0, width));
}
