import { sanitizeLabel } from "./sanitize.ts";
import type { ActorRosterItem, RosterProjection } from "./types.ts";

export type RosterEvent = { type: "ROSTER.FRAME"; frame: any } | { type: "ROSTER.RESET"; epoch: bigint; sequence?: bigint } | { type: "ROSTER.GAP"; reason: string };

export function initialRosterProjection(): RosterProjection { return { epoch: 0n, sequence: 0n, agents: new Map(), overflow: 0 }; }

export function reduceRoster(state: RosterProjection, event: RosterEvent): RosterProjection {
  if (event.type === "ROSTER.GAP") return { ...state, agents: new Map(), degradedReason: sanitizeLabel(event.reason, 120) ?? "roster gap" };
  if (event.type === "ROSTER.RESET") return event.epoch > state.epoch ? { epoch: event.epoch, sequence: event.sequence ?? 0n, agents: new Map(), overflow: 0 } : state;
  const frame = event.frame ?? {};
  const epoch = BigInt(frame.epoch ?? 0);
  const sequence = BigInt(frame.sequence ?? 0);
  if (epoch < state.epoch || (epoch === state.epoch && sequence <= state.sequence)) return state;
  const reset = epoch > state.epoch || Number(frame.operation) === 2;
  if (!reset && epoch === state.epoch && sequence !== state.sequence + 1n) return { ...state, degradedReason: "roster sequence gap" };
  const agents = new Map(reset ? [] : state.agents);
  if (Number(frame.operation) === 3) {
    const item = rosterItemFromFrame(frame);
    if (item) agents.set(item.agentId, item);
  }
  if (Number(frame.operation) === 4) {
    const agentId = sanitizeLabel(frame.agentId || frame.agent?.agentId, 64);
    if (agentId) agents.delete(agentId);
  }
  return { epoch, sequence, agents, overflow: 0 };
}

export function renderRosterStatus(connection: string, roster: RosterProjection, max = 120): { line?: string; overflow: number } {
  if (connection === "connecting" || connection === "authenticating" || connection === "subscribingRoster") return { line: "actors connecting", overflow: 0 };
  if (connection === "reconnecting") return { line: "actors reconnecting", overflow: 0 };
  if (connection === "degraded" || roster.degradedReason) return { line: `actors degraded${roster.degradedReason ? ` · ${roster.degradedReason}` : ""}`.slice(0, max), overflow: 0 };
  if (connection !== "connected") return { line: undefined, overflow: 0 };
  const parts = [...roster.agents.values()].sort((a, b) => a.agentId.localeCompare(b.agentId)).map((item) => `${item.displayName}:${item.lifecycle}`);
  let overflow = 0;
  let output = parts.length ? `actors ${parts.join(" ")}` : "actors none";
  while (output.length > max && parts.length) { parts.pop(); overflow++; output = parts.length ? `actors ${parts.join(" ")} +${overflow}` : `actors +${overflow}`; }
  return { line: sanitizeLabel(output, max) ?? "actors", overflow };
}

export function rosterItemFromFrame(frame: any): ActorRosterItem | undefined {
  const agent = frame.agent ?? {};
  const agentId = sanitizeLabel(frame.agentId || agent.agentId, 64);
  if (!agentId) return undefined;
  const displayName = sanitizeLabel(agent.displayName || agent.hostedPiRuntime?.displayName || agentId, 32) ?? agentId;
  const role = sanitizeLabel(agent.role || agent.hostedPiRuntime?.role, 24);
  return { agentId, displayName, role, lifecycle: rosterLifecycle(frame.status, agent), revision: BigInt(agent.lifecycleRevision ?? 0) };
}

function rosterLifecycle(status: unknown, agent: any): string {
  const value = sanitizeLabel(status, 24);
  if (value) return `[redacted] ${value}`;
  const state = Number(agent?.hostedPiRuntime?.state ?? 0);
  const names: Record<number, string> = { 1: "inactive", 2: "starting", 3: "ready", 4: "degraded", 5: "stopping", 6: "stopped" };
  return `[redacted] ${names[state] ?? "registered"}`;
}
