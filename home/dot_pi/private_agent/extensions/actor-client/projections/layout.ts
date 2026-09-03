import type { ConversationCard, ProjectionContext, RenderSnapshot } from "./types.ts";
import { renderRosterStatus } from "./roster.ts";

export function projectSnapshot(context: ProjectionContext, width = context.snapshot.width, themeRevision = context.snapshot.themeRevision): RenderSnapshot {
  const roster = renderRosterStatus(context.connection, context.roster, Math.max(24, Math.min(width, 120)));
  const firstPending = context.pending.values().next().value;
  const pending = firstPending ? context.pending.size === 1 ? `◌ Waiting for ${firstPending.target ?? firstPending.targetPeer?.displayName ?? "actor"}…` : `◌ actor asks ${context.pending.size} pending` : undefined;
  const cards = [...context.cards.values()].slice(-context.maxCards);
  const executorLine = context.executor.current ? `executor ${context.executor.state ?? "idle"}` : undefined;
  const presentationAckLine = context.pendingPresentation.size ? `◌ waiting for presentation ack (${context.pendingPresentation.size})` : undefined;
  const continuationLine = context.affordances.continuations.size ? `↻ ${context.affordances.continuations.size} continuation${context.affordances.continuations.size === 1 ? "" : "s"} available` : undefined;
  const introspectionLine = context.affordances.introspections.size ? `ⓘ ${context.affordances.introspections.size} introspection${context.affordances.introspections.size === 1 ? "" : "s"} available` : undefined;
  return { connection: context.connection, statusLine: roster.line, pendingLine: pending, cards, width, overflow: roster.overflow + Math.max(0, context.cards.size - cards.length), themeRevision, inputState: context.turnAdmission.state, executorLine, presentationAckLine, continuationLine, introspectionLine };
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
  const bodyLines = [`${icon} ${title}`, ...wrapPlain(card.body, inner)];
  if (card.reply) bodyLines.push("", `↙ ${card.peerDisplayName} replied`, ...wrapPlain(card.reply, inner));
  const footer = card.state === "failed" ? "retry available" : card.state === "pending" ? `◌ Waiting for ${card.peerDisplayName}…` : card.state === "replied" ? `✓ replied${card.durationMillis !== undefined ? ` in ${formatDuration(card.durationMillis)}` : ""}` : "✓ delivered";
  if (narrow) return [...bodyLines, footer].map((line) => line.slice(0, width));
  return ["╭─ " + bodyLines[0], ...bodyLines.slice(1).map((line) => `│ ${line}`.slice(0, width)), `╰─ ${footer}`].map((line) => line.slice(0, width));
}

function formatDuration(milliseconds: number): string {
  return milliseconds < 1000 ? `${Math.max(1, Math.round(milliseconds))}ms` : `${Math.round(milliseconds / 1000)}s`;
}
