import type { RendererIntent } from "./actor-events.ts";
import type { Projection } from "../domain/projection.ts";

export const IPC_SCHEMA_VERSION = 1 as const;
export const MAX_IPC_FRAME_BYTES = 64 * 1024;
export const MAX_INPUTS_PER_SECOND = 20;

export type ClientFrame =
  | { version: 1; sequence: number; type: "authenticate"; ticketId: string; generation: string; nonce: string; reconnect?: boolean }
  | { version: 1; sequence: number; type: "intent"; intent: RendererIntent };

export type ServerFrame =
  | { version: 1; sequence: number; type: "authenticated"; connectionId: string; reconnectNonce: string }
  | { version: 1; sequence: number; type: "snapshot"; projection: Projection; delivery?: { ok: boolean; message: string }; supervisors?: Record<string, string> }
  | { version: 1; sequence: number; type: "result"; requestId: string; ok: boolean; message: string }
  | { version: 1; sequence: number; type: "fatal"; message: string };
