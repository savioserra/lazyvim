import { activityForAgent } from "./activity.ts";
import type { ActorUiRow, ActorUiSnapshot, ConversationCard, ProjectionContext, RenderSnapshot } from "./types.ts";
import { renderRosterStatus } from "./roster.ts";

export function projectSnapshot(context: ProjectionContext, width = context.snapshot.width, themeRevision = context.snapshot.themeRevision): RenderSnapshot {
  const roster = renderRosterStatus(context.connection, context.roster, Math.max(24, Math.min(width, 120)));
  const firstPending = context.pending.values().next().value;
  const pending = firstPending ? context.pending.size === 1 ? `◌ Waiting for ${firstPending.target ?? firstPending.targetPeer?.displayName ?? "actor"}…` : `◌ actor asks ${context.pending.size} pending` : undefined;
  const cards = [...context.cards.values()].slice(-context.maxCards);
  const actorStatus = projectActorStatusSnapshot(context, roster.line, width, themeRevision);
  return { connection: context.connection, statusLine: actorStatus.footer, pendingLine: pending, cards, width, overflow: actorStatus.overflow + Math.max(0, context.cards.size - cards.length), themeRevision, actorStatus };
}

export function projectActorStatusSnapshot(context: ProjectionContext, rosterLine?: string, width = context.snapshot.width, themeRevision = context.snapshot.themeRevision): ActorUiSnapshot {
  const pendingTargets = new Map<string, number>();
  for (const pending of context.pending.values()) {
    const target = pending.targetPeer?.stableId || pending.target;
    if (target) pendingTargets.set(target, (pendingTargets.get(target) ?? 0) + 1);
  }
  const rows: ActorUiRow[] = [...context.roster.agents.values()].sort((a, b) => a.agentId.localeCompare(b.agentId)).map((agent) => {
    const live = context.connection === "connected";
    const activities = live ? activityForAgent(context.activity, agent.agentId) : [];
    const pending = live && ((pendingTargets.get(agent.agentId) ?? pendingTargets.get(agent.displayName) ?? 0) > 0 || activities.some((activity) => activity.pending));
    return { agentId: agent.agentId, displayName: agent.displayName, role: agent.role, lifecycle: live ? agent.lifecycle : rowConnectionLifecycle(context.connection), activity: activities[0]?.label, pending };
  });
  const visibleRows = rows.slice(0, 20);
  const overflow = Math.max(0, rows.length - visibleRows.length) + context.roster.overflow;
  const transient = context.connection === "connecting" || context.connection === "authenticating" || context.connection === "subscribingRoster" || context.connection === "reconnecting" || context.connection === "closing";
  const facts = transient ? [rosterLine] : [rosterLine, context.pending.size ? context.pending.size === 1 ? "1 pending" : `${context.pending.size} pending` : undefined, context.activity.threads.size ? `${context.activity.threads.size} active` : undefined].filter(Boolean) as string[];
  return Object.freeze({ connection: context.connection, footer: facts.join(" · ") || undefined, rows: Object.freeze(visibleRows.map((row) => Object.freeze({ ...row }))) as unknown as ActorUiRow[], overflow, width, themeRevision, revision: context.revision });
}

function rowConnectionLifecycle(connection: string): string {
  if (connection === "subscribingRoster") return "subscribing";
  if (connection === "reconnecting") return "reconnecting";
  if (connection === "connecting" || connection === "authenticating") return "connecting";
  if (connection === "closing") return "closing";
  if (connection === "degraded") return "degraded";
  return "unavailable";
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
