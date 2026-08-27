import type { AuthorityIdentity } from "../domain/types.ts";
import type { ActorEvent, RendererIntent } from "./actor-events.ts";
import { IPC_SCHEMA_VERSION, MAX_IPC_FRAME_BYTES, type ClientFrame } from "./ipc-envelope.ts";

export function validAuthorityIdentity(identity: unknown): identity is AuthorityIdentity {
  if (!identity || typeof identity !== "object" || Array.isArray(identity)) return false;
  const value = identity as Record<string, unknown>;
  return typeof value.runId === "string" && value.runId.length > 0 && value.runId.length <= 160 &&
    (value.childId === undefined || (typeof value.childId === "string" && value.childId.length > 0 && value.childId.length <= 160));
}

export function assertRendererIntent(value: unknown): RendererIntent {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("renderer intent must be an object");
  const intent = value as Record<string, unknown>;
  if (typeof intent.kind !== "string" || !["select", "refresh", "steer", "interrupt", "stop", "resume", "detach"].includes(intent.kind)) throw new Error("renderer intent kind is invalid");
  if (intent.identity !== undefined && !validAuthorityIdentity(intent.identity)) throw new Error("renderer intent identity is invalid");
  if (intent.kind === "select" && !["next", "previous", "parent", "child"].includes(String(intent.direction))) throw new Error("renderer selection is invalid");
  if (intent.kind === "steer" && (typeof intent.text !== "string" || intent.text.trim().length < 1 || intent.text.length > 4000)) throw new Error("renderer steer text is invalid");
  if (intent.kind === "resume" && (intent.confirmed !== true || typeof intent.text !== "string" || intent.text.trim().length < 1 || intent.text.length > 4000)) throw new Error("renderer resume request is invalid");
  if ((intent.kind === "interrupt" || intent.kind === "stop") && intent.confirmed !== true) throw new Error(`${intent.kind} requires confirmation`);
  return intent as RendererIntent;
}

export function assertActorEvent(value: unknown): ActorEvent {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("actor event must be an object");
  const event = value as Record<string, unknown>;
  if (typeof event.type !== "string" || !/^[A-Z]+(?:[._][A-Z]+)+$/.test(event.type)) throw new Error("actor event type is invalid");
  return event as ActorEvent;
}

export function parseClientFrame(line: string): ClientFrame {
  if (Buffer.byteLength(line, "utf8") > MAX_IPC_FRAME_BYTES) throw new Error("IPC frame exceeds byte limit");
  const value: unknown = JSON.parse(line);
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error("IPC frame must be an object");
  const frame = value as Record<string, unknown>;
  if (frame.version !== IPC_SCHEMA_VERSION || !Number.isSafeInteger(frame.sequence) || Number(frame.sequence) < 1 || typeof frame.type !== "string") throw new Error("IPC frame schema is incompatible");
  return frame as unknown as ClientFrame;
}
