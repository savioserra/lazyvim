import { sanitizeLabel } from "./sanitize.ts";
import type { ActivityProjection, ActivityThread, ActorActivityFrame } from "./types.ts";

export type ActivityEvent =
  | { type: "ACTIVITY.FRAME"; frame: ActorActivityFrame }
  | { type: "ACTIVITY.CLEAR"; agentId?: string; threadId?: string; epoch?: bigint; sequence?: bigint }
  | { type: "ACTIVITY.GAP"; reason: string };

export function initialActivityProjection(): ActivityProjection {
  return { epoch: 0n, sequence: 0n, threads: new Map() };
}

export function adaptActorActivityFrame(frame: unknown): ActorActivityFrame | undefined {
  const value = (frame ?? {}) as any;
  const activity = value.activity ?? {};
  const operation = normalizeOperation(value.operation ?? value.op ?? value.kind ?? (activity.cleared ? "clear" : undefined));
  const agentId = sanitizeLabel(value.agentId ?? value.actorId ?? value.targetAgentId ?? activity.ownerAgentId, 64);
  if (!agentId && operation !== "reset") return undefined;
  return {
    epoch: BigInt(value.epoch ?? 0),
    sequence: BigInt(value.sequence ?? value.seq ?? 0),
    operation,
    agentId,
    threadId: sanitizeLabel(value.threadId ?? value.requestId ?? value.completionKey ?? activity.activityKey ?? agentId, 96) ?? agentId,
    label: sanitizeLabel(value.label ?? activity.label ?? value.status ?? value.kind, 48),
    pending: Boolean(value.pending ?? value.awaitingReply ?? (operation === "upsert" && !activity.cleared)),
  };
}

export function reduceActivity(state: ActivityProjection, event: ActivityEvent): ActivityProjection {
  if (event.type === "ACTIVITY.GAP") return { ...state, threads: new Map(), degradedReason: sanitizeLabel(event.reason, 120) ?? "activity gap" };
  if (event.type === "ACTIVITY.CLEAR") {
    const epoch = BigInt(event.epoch ?? state.epoch);
    const sequence = BigInt(event.sequence ?? state.sequence + 1n);
    const fenced = acceptFence(state, epoch, sequence, true);
    if (!fenced.accept) return state;
    const threads = new Map(state.threads);
    for (const [key, thread] of threads) {
      if ((!event.agentId || thread.agentId === event.agentId) && (!event.threadId || thread.threadId === event.threadId)) threads.delete(key);
    }
    return { epoch, sequence, threads };
  }
  const frame = adaptActorActivityFrame(event.frame);
  if (!frame) return state;
  const fenced = acceptFence(state, frame.epoch, frame.sequence, frame.operation === "reset");
  if (!fenced.accept) return fenced.degradedReason ? { ...state, degradedReason: fenced.degradedReason } : state;
  const threads = new Map(frame.operation === "reset" ? [] : state.threads);
  if (frame.operation === "clear") {
    for (const [key, thread] of threads) if (thread.agentId === frame.agentId && (!frame.threadId || thread.threadId === frame.threadId)) threads.delete(key);
  } else if (frame.operation === "upsert" && frame.agentId && frame.threadId) {
    const thread: ActivityThread = { agentId: frame.agentId, threadId: frame.threadId, label: naturalizeActivity(frame.label), pending: !!frame.pending };
    threads.set(activityKey(thread.agentId, thread.threadId), thread);
  }
  return { epoch: frame.epoch, sequence: frame.sequence, threads };
}

export function activityForAgent(activity: ActivityProjection, agentId: string): ActivityThread[] {
  return [...activity.threads.values()].filter((thread) => thread.agentId === agentId).sort((a, b) => a.threadId.localeCompare(b.threadId));
}

function activityKey(agentId: string, threadId: string): string { return `${agentId}\0${threadId}`; }

function normalizeOperation(value: unknown): ActorActivityFrame["operation"] {
  if (value === 1) return "reset";
  if (value === 2) return "upsert";
  if (value === 3) return "clear";
  const text = String(value ?? "").toLowerCase();
  if (text === "reset" || text === "snapshot" || text === "snapshot_reset") return "reset";
  if (text === "clear" || text === "delete" || text === "remove") return "clear";
  return "upsert";
}

function acceptFence(state: ActivityProjection, epoch: bigint, sequence: bigint, reset: boolean): { accept: boolean; degradedReason?: string } {
  if (epoch < state.epoch || (epoch === state.epoch && sequence <= state.sequence)) return { accept: false };
  if (epoch > state.epoch && !reset) return { accept: false, degradedReason: "higher activity epoch arrived without reset" };
  if (!reset && epoch === state.epoch && sequence !== state.sequence + 1n) return { accept: false, degradedReason: "activity sequence gap" };
  return { accept: true };
}

function naturalizeActivity(value: unknown): string {
  const label = sanitizeLabel(value, 48)?.toLowerCase().replace(/[_.-]+/g, " ").replace(/\s+/g, " ").trim();
  if (!label) return "active";
  if (/^(ask|prompt|request|waiting)$/.test(label)) return "waiting";
  if (/^(tell|note|message|send)$/.test(label)) return "messaging";
  if (/^(complete|completed|done|idle|clear)$/.test(label)) return "active";
  return label.replace(/\b\w/g, (letter) => letter.toUpperCase());
}
