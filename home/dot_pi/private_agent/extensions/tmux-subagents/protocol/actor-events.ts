import { createHash } from "node:crypto";
import type { AuthorityIdentity, ControlOperation } from "../domain/types.ts";
export type { AuthorityIdentity, ControlOperation } from "../domain/types.ts";

export const ACTOR_PROTOCOL_VERSION = 1 as const;

export type ActorEvent =
  | { type: "AUTHORITY.HINT"; source: string }
  | { type: "AUTHORITY.SNAPSHOT"; snapshot: unknown }
  | { type: "RUN.DESIRED"; identity: AuthorityIdentity }
  | { type: "RUN.REMOVED"; identity: AuthorityIdentity }
  | { type: "VIEW.DESIRED"; bindingId: string; identity: AuthorityIdentity }
  | { type: "VIEW.REMOVED"; bindingId: string }
  | { type: "RENDER.CONNECTED"; connectionId: string; bindingId: string }
  | { type: "RENDER.DISCONNECTED"; connectionId: string; bindingId: string; reason: string }
  | { type: "RENDER.INPUT"; connectionId: string; intent: RendererIntent }
  | { type: "SELECTION.CHANGED"; connectionId: string; identity: AuthorityIdentity }
  | { type: "CONTROL.REQUEST"; requestId: string; identity: AuthorityIdentity; operation: ControlOperation; text?: string; confirmed?: boolean }
  | { type: "CONTROL.RESULT"; requestId: string; ok: boolean; message: string }
  | { type: "CHILD.FAILED"; childId: string; reason: string; abnormal: boolean; at: number }
  | { type: "CHILD.EXITED"; childId: string; abnormal: boolean; reason: string; at: number }
  | { type: "SUPERVISOR.START" }
  | { type: "SUPERVISOR.STOP" }
  | { type: "SUPERVISOR.RESTART_DUE"; childIds: string[] }
  | { type: "SUPERVISOR.RECEIPT"; supervisorId: string; childId: string; decision: "ignore" | "restart" | "circuit-open" | "escalate"; reason: string; at: number; restartAttempt: number };

export type RendererIntent =
  | { kind: "select"; direction: "next" | "previous" | "parent" | "child"; identity?: AuthorityIdentity }
  | { kind: "refresh" }
  | { kind: "steer"; text: string; identity?: AuthorityIdentity }
  | { kind: "interrupt"; confirmed: boolean; identity?: AuthorityIdentity }
  | { kind: "stop"; confirmed: boolean; identity?: AuthorityIdentity }
  | { kind: "resume"; confirmed: boolean; text: string; identity?: AuthorityIdentity }
  | { kind: "detach" };

export function stableSystemId(scope: string, ...identity: string[]): string {
  const digest = createHash("sha256").update([scope, ...identity].join("\0")).digest("hex").slice(0, 24);
  return `${scope}:${digest}`;
}
