import { randomUUID } from "node:crypto";
import {
  ASYNC_SNAPSHOT_KIND,
  ASYNC_SNAPSHOT_VERSION,
  EXTENSION_ID,
  RPC_PROTOCOL_VERSION,
  RPC_REPLY_PREFIX,
  RPC_REQUEST_EVENT,
} from "../domain/constants.ts";
import { decodeAsyncSnapshot, sanitizeText, type Projection } from "../domain/projection.ts";

export interface EventBus {
  on(event: string, listener: (payload: unknown) => void | Promise<void>): void | (() => void);
  emit(event: string, payload: unknown): void;
}

interface RpcReply {
  version: number;
  requestId: string;
  method?: string;
  success: boolean;
  data?: unknown;
  error?: { code?: unknown; message?: unknown };
}

function object(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be an object`);
  return value as Record<string, unknown>;
}

function decodeReply(value: unknown, requestId: string, method: string): unknown {
  const reply = object(value, "RPC reply") as unknown as RpcReply;
  if (reply.version !== RPC_PROTOCOL_VERSION || reply.requestId !== requestId || reply.method !== method) {
    throw new Error(`incompatible RPC reply for ${method}`);
  }
  if (!reply.success) {
    const code = typeof reply.error?.code === "string" ? reply.error.code : "rpc_failed";
    const message = typeof reply.error?.message === "string" ? reply.error.message : "unknown RPC failure";
    throw new Error(`${code}: ${message}`);
  }
  return reply.data;
}

export type SubagentsRpcMethod = "ping" | "status" | "steer" | "interrupt" | "stop" | "resume";

export interface CompatiblePing {
  sessionId?: string;
  methods: ReadonlySet<SubagentsRpcMethod>;
  events: { asyncComplete: string; childStatus: string; processTerminal: string };
}

export function decodeCompatiblePing(value: unknown): CompatiblePing {
  const data = object(value, "ping data");
  if (data.version !== RPC_PROTOCOL_VERSION || !Array.isArray(data.methods)) throw new Error("unsupported pi-subagents RPC protocol");
  for (const method of ["ping", "status", "steer", "interrupt", "stop", "resume"]) {
    if (!data.methods.includes(method)) throw new Error(`pi-subagents RPC is missing ${method}`);
  }
  const capabilities = object(data.capabilities, "ping capabilities");
  const snapshot = object(capabilities.asyncStatusSnapshot, "async status snapshot capability");
  if (snapshot.kind !== ASYNC_SNAPSHOT_KIND || snapshot.version !== ASYNC_SNAPSHOT_VERSION) {
    throw new Error("pi-subagents async snapshot capability is incompatible");
  }
  const events = object(data.events, "ping events");
  for (const [key, expected] of [
    ["asyncComplete", "subagent:async-complete"],
    ["childStatus", "subagent:child-status"],
    ["processTerminal", "subagent:process-terminal"],
  ] as const) {
    if (events[key] !== expected) throw new Error(`pi-subagents advertised incompatible ${key} event`);
  }
  const session = data.session === undefined ? {} : object(data.session, "ping session");
  return {
    sessionId: typeof session.sessionId === "string" ? session.sessionId : undefined,
    methods: new Set(data.methods as SubagentsRpcMethod[]),
    events: {
      asyncComplete: events.asyncComplete as string,
      childStatus: events.childStatus as string,
      processTerminal: events.processTerminal as string,
    },
  };
}

export class SubagentsRpcClient {
  private readonly events: EventBus;
  private readonly timeoutMs: number;

  constructor(events: EventBus, timeoutMs = 3000) {
    this.events = events;
    this.timeoutMs = timeoutMs;
  }

  request(method: SubagentsRpcMethod, params: Record<string, unknown> = {}): Promise<unknown> {
    const requestId = randomUUID();
    const replyEvent = RPC_REPLY_PREFIX + requestId;
    return new Promise((resolve, reject) => {
      let settled = false;
      const finish = (error?: Error, value?: unknown) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (typeof unsubscribe === "function") unsubscribe();
        error ? reject(error) : resolve(value);
      };
      const unsubscribe = this.events.on(replyEvent, (reply) => {
        try {
          finish(undefined, decodeReply(reply, requestId, method));
        } catch (error) {
          finish(error instanceof Error ? error : new Error(String(error)));
        }
      });
      const timer = setTimeout(() => finish(new Error(`pi-subagents RPC ${method} timed out`)), this.timeoutMs);
      timer.unref?.();
      this.events.emit(RPC_REQUEST_EVENT, {
        version: RPC_PROTOCOL_VERSION,
        requestId,
        method,
        params,
        source: { extension: EXTENSION_ID },
      });
    });
  }

  async ping(): Promise<CompatiblePing> {
    return decodeCompatiblePing(await this.request("ping"));
  }

  async status(): Promise<Projection> {
    const data = object(await this.request("status"), "status data");
    return decodeAsyncSnapshot(data.asyncSnapshot);
  }

  async control(method: Exclude<SubagentsRpcMethod, "ping" | "status">, identity: { runId: string; childId?: string }, message?: string): Promise<{ message: string; data: unknown }> {
    const target = identity.childId && method !== "stop" ? identity.childId : identity.runId;
    const params: Record<string, unknown> = { id: target };
    if (identity.childId && method === "stop") params.childId = identity.childId;
    if (method === "steer" || method === "resume") {
      const bounded = typeof message === "string" ? message.trim().slice(0, 4000) : "";
      if (!bounded) throw new Error(`${method} requires a non-empty message`);
      params.message = bounded;
      if (method === "steer") params.mode = "steer";
    }
    const data = await this.request(method, params);
    const result = object(data, `${method} data`);
    const text = sanitizeText(result.text, `${method} acknowledged`, 1000);
    return { message: text, data };
  }
}
