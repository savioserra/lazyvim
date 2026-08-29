import { modelResultContent, naturalResultSummary, renderToolCall, renderToolResult } from "./communication-ui.ts";

export const HOSTED_ENVIRONMENT = ["WS_SUBAGENTS_ENDPOINT", "WS_SUBAGENTS_CREDENTIAL_FILE", "WS_SUBAGENTS_SESSION_ID", "WS_SUBAGENTS_GENERATION_ID", "WS_SUBAGENTS_CALLER", "WS_SUBAGENTS_AGENT_ID", "WS_SUBAGENTS_RUNTIME_ID", "WS_SUBAGENTS_INCARNATION"] as const;

export function completeHostedEnvironment(environment: NodeJS.ProcessEnv): boolean {
  const values = HOSTED_ENVIRONMENT.map((name) => environment[name]);
  if (values.every((value) => !value)) return false;
  if (values.some((value) => !value || value !== value.trim() || /[\0\r\n]/.test(value))) return false;
  try { return BigInt(environment.WS_SUBAGENTS_INCARNATION!) > 0n; } catch { return false; }
}

export function parseTargetMessage(args: string): [string | undefined, string] {
  const marker = args.indexOf(" -- ");
  return marker < 0 ? [undefined, args.trim()] : [args.slice(0, marker).trim() || undefined, args.slice(marker + 4).trim()];
}

export function requireExplicitModelTarget(target?: string): string {
  const value = target?.trim();
  if (!value) throw new Error("model actor tools require an explicit target");
  return value;
}

export async function destroyOnFramingFailure<T>(socket: { destroy(error?: Error): void }, operation: () => Promise<T>): Promise<T> {
  try { return await operation(); }
  catch (error) { socket.destroy(error instanceof Error ? error : undefined); throw error; }
}

export async function drainPages<T extends { latestSequence: bigint; more: boolean }>(initial: bigint, fetch: (after: bigint) => Promise<T>, consume: (page: T) => Promise<void>): Promise<bigint> {
  let cursor = initial;
  for (;;) {
    const page = await fetch(cursor);
    await consume(page);
    if (page.more && page.latestSequence === cursor) throw new Error("bridge poll cursor did not advance");
    cursor = page.latestSequence;
    if (!page.more) return cursor;
  }
}

export type MutationAdmission = { accepted: boolean };
type UnresolvedMutation = { sequence: bigint; logical: unknown; attempt(logical: unknown): Promise<MutationAdmission>; reconcile(): Promise<void> };
type MutationScopeState = { highWater: bigint; tail: Promise<void>; unresolved?: UnresolvedMutation };

// ExactMutationSequencer retains at most one unresolved immutable mutation per
// authenticated target fence. Later calls must settle it before allocating the
// next sequence; per-invocation retry exhaustion never discards identity.
export class ExactMutationSequencer {
  private readonly scopes = new Map<string, MutationScopeState>();
  async run<TLogical, TResult extends MutationAdmission>(scopeKey: string, create: (sequence: bigint) => TLogical, attempt: (logical: TLogical) => Promise<TResult>, reconcile: () => Promise<void>): Promise<TResult> {
    let scope = this.scopes.get(scopeKey);
    if (!scope) { scope = { highWater: 0n, tail: Promise.resolve() }; this.scopes.set(scopeKey, scope); }
    const operation = scope.tail.then(async () => {
      if (scope!.unresolved) await this.settle(scope!, scope!.unresolved);
      const sequence = scope!.highWater + 1n;
      const logical = create(sequence);
      const unresolved: UnresolvedMutation = { sequence, logical, attempt: attempt as (logical: unknown) => Promise<MutationAdmission>, reconcile };
      scope!.unresolved = unresolved;
      return await this.settle(scope!, unresolved) as TResult;
    });
    scope.tail = operation.then(() => undefined, () => undefined);
    return operation;
  }
  retireScope(scopeKey: string, oldAuthorizationRevoked: boolean): void {
    if (!oldAuthorizationRevoked) throw new Error("cannot retire unresolved mutation before old fence revocation proof");
    this.scopes.delete(scopeKey);
  }
  unresolvedCount(): number { let count=0;for(const scope of this.scopes.values())if(scope.unresolved)count++;return count; }
  private async settle(scope: MutationScopeState, unresolved: UnresolvedMutation): Promise<MutationAdmission> {
    let lastError: unknown;
    for (let retry=0;retry<5;retry++) {
      try {
        const result=await unresolved.attempt(unresolved.logical);
        if(result.accepted)scope.highWater=unresolved.sequence;
        if(scope.unresolved===unresolved)scope.unresolved=undefined;
        return result;
      } catch(error) {
        lastError=error;
        try { await unresolved.reconcile(); } catch(reconnectError) { lastError=reconnectError; }
        if(retry<4)await new Promise<void>((resolve)=>setTimeout(resolve,Math.min(160,10*2**retry)));
      }
    }
    throw lastError instanceof Error ? lastError : new Error("logical mutation reconciliation exhausted");
  }
}

export function mutationScopeKey(target: { handle: string; fence: bigint }, incarnation: bigint): string { return `${target.handle}\0${target.fence}\0${incarnation}`; }

export type CommunicationPeer = { stableId?: string; stable_id?: string; displayName?: string; display_name?: string; role?: string };
export type CommunicationEntry = { key: string; line: string };

export class CommunicationTimeline {
  private readonly entries: CommunicationEntry[] = [];
  private readonly seen = new Set<string>();
  private readonly limit: number;
  constructor(limit = 8) { this.limit = limit; }
  add(entry: CommunicationEntry): boolean {
    if (this.seen.has(entry.key)) return false;
    this.seen.add(entry.key);
    this.entries.push(entry);
    while (this.entries.length > this.limit) this.entries.shift();
    while (this.seen.size > this.limit * 4) this.seen.delete(this.seen.values().next().value!);
    return true;
  }
  lines(): string[] { return this.entries.map((entry) => entry.line); }
}

export function communicationLine(source: CommunicationPeer | undefined, target: CommunicationPeer | undefined, kind: string, previewBytes?: Uint8Array | string): string {
  const text = `${peerLabel(source)} → ${peerLabel(target)} · ${boundedAtom(kind, 24)} — ${boundedPreview(previewBytes)}`;
  return boundedAtom(text.replace(/[\r\n\t\x00]/g, " "), 160);
}

export function communicationKey(delivery: { dedupeId?: string; sequence?: bigint | number; kind?: number | string }): string {
  return `${delivery.dedupeId ?? ""}\0${String(delivery.sequence ?? "")}\0${String(delivery.kind ?? "")}`;
}

function peerLabel(peer?: CommunicationPeer): string {
  const display = peer?.displayName ?? peer?.display_name ?? "UNKNOWN";
  const role = peer?.role ? ` (${peer.role})` : "";
  return boundedAtom(`${display}${role}`, 48);
}

function boundedPreview(value?: Uint8Array | string): string {
  const text = typeof value === "string" ? value : value ? new TextDecoder("utf-8", { fatal: false }).decode(value) : "";
  const clean = text.replace(/[\r\n\t\x00]/g, " ").replace(/\b(session|credential|handle|fence|pid)\S*/gi, "[redacted]");
  return boundedAtom(clean, 72);
}

function boundedAtom(value: string, max: number): string {
  return value.length > max ? `${value.slice(0, Math.max(0, max - 1))}…` : value;
}

export type HostedHandlerOperations = {
  list(): Promise<unknown>;
  resolve(target?: string): Promise<unknown>;
  health(target?: string): Promise<unknown>;
  message(mode: number, target: string | undefined, text: string): Promise<unknown>;
  control(intent: number, target?: string): Promise<unknown>;
  subscribe(target?: string): Promise<unknown>;
  unsubscribe(target?: string): Promise<unknown>;
};

type CommandContext = { ui: { notify(message: string, level: string): void } };
type RegistrationAPI = {
  registerCommand(name: string, registration: { description: string; handler(args: string, ctx: CommandContext): Promise<void> }): void;
  registerTool(registration: { name: string; label: string; description: string; parameters: unknown; execute(id: string, params: any): Promise<unknown>; renderCall?(args: any, theme: any, context: any): unknown; renderResult?(result: any, options: any, theme: any, context: any): unknown }): void;
};

export function registerHostedHandlers(api: RegistrationAPI, operations: HostedHandlerOperations, schemas: { empty: unknown; target: unknown; modelTarget: unknown; message: unknown }) {
  const notify = (ctx: CommandContext, name: string, value: unknown) => ctx.ui.notify(naturalResultSummary(name, value), "info");
  api.registerCommand("actor-list", { description: "List authorized logical actors", handler: async (_args, ctx) => notify(ctx, "actor_list", await operations.list()) });
  api.registerCommand("actor-resolve", { description: "Resolve a logical actor; omitted target means self", handler: async (args, ctx) => notify(ctx, "actor_resolve", await operations.resolve(args)) });
  api.registerCommand("actor-health", { description: "Ping a logical actor; omitted target means self", handler: async (args, ctx) => notify(ctx, "actor_health", await operations.health(args)) });
  api.registerCommand("actor-tell", { description: "Tell a logical actor asynchronously: [target] -- message; omitted target means self", handler: async (args, ctx) => { const [target, text] = parseTargetMessage(args); notify(ctx, "actor_tell", await operations.message(2, target, text)); } });
  api.registerCommand("actor-abort", { description: "Abort a hosted actor using control_abort", handler: async (args, ctx) => notify(ctx, "actor_abort", await operations.control(1, args)) });
  api.registerCommand("actor-shutdown", { description: "Shutdown a hosted actor using control_shutdown", handler: async (args, ctx) => notify(ctx, "actor_shutdown", await operations.control(2, args)) });
  api.registerCommand("actor-subscribe", { description: "Subscribe to actor events", handler: async (args, ctx) => notify(ctx, "actor_subscribe", await operations.subscribe(args)) });
  api.registerCommand("actor-unsubscribe", { description: "Unsubscribe from actor events", handler: async (args, ctx) => notify(ctx, "actor_unsubscribe", await operations.unsubscribe(args)) });
  const tool = (name: string, description: string, parameters: unknown, execute: (params: any) => Promise<unknown>) => api.registerTool({ name, label: name, description, parameters, async execute(_id, params) { const result = await execute(params); return { content: [{ type: "text", text: modelResultContent(name, result) }], details: result }; }, renderCall(args, theme, context) { return renderToolCall(name, args, theme); }, renderResult(result, options, theme, context) { return renderToolResult(name, result, options, theme); } });
  tool("actor_list", "List authorized logical actors", schemas.empty, async () => operations.list());
  tool("actor_resolve", "Resolve a logical actor", schemas.modelTarget, async (params) => operations.resolve(requireExplicitModelTarget(params.target)));
  tool("actor_health", "Ping actor reachability and details", schemas.modelTarget, async (params) => operations.health(requireExplicitModelTarget(params.target)));
  tool("actor_tell", "Tell a logical actor asynchronously", schemas.message, async (params) => operations.message(2, requireExplicitModelTarget(params.target), params.message));
  tool("actor_abort", "Abort a hosted actor", schemas.modelTarget, async (params) => operations.control(1, requireExplicitModelTarget(params.target)));
  tool("actor_shutdown", "Shutdown a hosted actor", schemas.modelTarget, async (params) => operations.control(2, requireExplicitModelTarget(params.target)));
  tool("actor_subscribe", "Subscribe to bounded events", schemas.modelTarget, async (params) => operations.subscribe(requireExplicitModelTarget(params.target)));
  tool("actor_unsubscribe", "Unsubscribe from actor events", schemas.modelTarget, async (params) => operations.unsubscribe(requireExplicitModelTarget(params.target)));
}

export function buildActorMessage(mode: number, target: string, text: string, dedupeId: string, chainId: string, sourceMutationSequence: bigint, hopLimit = 8) {
  const boundedPayload = new TextEncoder().encode(text);
  if (!text || boundedPayload.byteLength > 16 * 1024) throw new Error("message must be non-empty and within the 16 KiB bound");
  if (sourceMutationSequence <= 0n || hopLimit < 1) throw new Error("source mutation sequence and hop limit must be positive");
  return { mode, target, boundedPayload, dedupeId, hopLimit, chainId, sourceMutationSequence };
}
export function buildActorControl(intent: number, target: string, dedupeId: string, chainId: string, sourceMutationSequence: bigint, hopLimit = 2) {
  if (sourceMutationSequence <= 0n || hopLimit < 1) throw new Error("source mutation sequence and hop limit must be positive");
  return { intent, target, dedupeId, hopLimit, chainId, sourceMutationSequence };
}
export function buildDeliveryAck(agentId: string, delivery: { sequence: bigint; dedupeId: string }, delivered: boolean, reason: string, boundedResult = new Uint8Array()) { return { agentId, sequence: delivery.sequence, dedupeId: delivery.dedupeId, delivered, reason, boundedResult }; }

export async function invokeTypedDeliveryForAck(agentId: string, delivery: { sequence: bigint; dedupeId: string }, invoke: () => void | Promise<void>) {
  try { await invoke(); return buildDeliveryAck(agentId, delivery, true, ""); }
  catch (error) { return buildDeliveryAck(agentId, delivery, false, error instanceof Error ? error.message : "delivery failed"); }
}

export function executeTypedDelivery(ctx: { abort(): void; shutdown(): void; ui: { notify(message: string, level: string): void } }, kind: number, text: string) {
  const action = deliveryAction(kind);
  if (action === "abort") ctx.abort();
  else if (action === "shutdown") ctx.shutdown();
  else ctx.ui.notify(text.slice(0, 1024), "info");
}

export type PromptDelivery = { dedupeId: string; boundedPayload: Uint8Array; hopLimit: number; deadlineUnixMillis: bigint; chainId: string; sequence: bigint };
export class PromptTaskCoordinator<TFence> {
  private pending?: { delivery: PromptDelivery; fence: TFence };
  private outcome?: { delivered: boolean; answer: string; reason: string };
  private readonly sendUserMessage: (text: string) => void;
  private readonly acknowledge: (pending: { delivery: PromptDelivery; fence: TFence }, delivered: boolean, answer: string, reason: string) => Promise<void>;
  constructor(sendUserMessage: (text: string) => void, acknowledge: (pending: { delivery: PromptDelivery; fence: TFence }, delivered: boolean, answer: string, reason: string) => Promise<void>) { this.sendUserMessage=sendUserMessage;this.acknowledge=acknowledge; }
  active() { return this.pending; }
  async retryCompletion() { if (this.pending && this.outcome) await this.flush(); }
  async deliver(delivery: PromptDelivery, fence: TFence) {
    if (this.pending) {
      if (this.pending.delivery.dedupeId !== delivery.dedupeId) throw new Error("a different prompt task is already active");
      return;
    }
    if (delivery.hopLimit < 1 || BigInt(Date.now()) > delivery.deadlineUnixMillis) throw new Error("prompt hop budget or deadline expired");
    const text = new TextDecoder("utf-8", { fatal: true }).decode(delivery.boundedPayload);
    if (!text) throw new Error("prompt is empty");
    this.pending = { delivery, fence };
    try { this.sendUserMessage(text); }
    catch (error) { await this.finish(false, "", error instanceof Error ? error.message : "prompt injection failed"); }
  }
  async agentEnd(messages: unknown[]) { if (this.pending) { const answer=boundedAssistantAnswer(messages);await this.finish(Boolean(answer),answer,answer?"":"prompt run ended without an assistant answer"); } }
  async shutdown() { if (this.pending) await this.finish(false,"","hosted Pi session shut down before prompt completion"); }
  private async finish(delivered:boolean,answer:string,reason:string){if(!this.pending)return;this.outcome={delivered,answer,reason};await this.flush();}
  private async flush(){const pending=this.pending,outcome=this.outcome;if(!pending||!outcome)return;await this.acknowledge(pending,outcome.delivered,outcome.answer,outcome.reason);if(this.pending===pending){this.pending=undefined;this.outcome=undefined;}}
}
export function boundedAssistantAnswer(messages: unknown[]): string {
  for (let index=messages.length-1;index>=0;index--){const message=messages[index] as {role?:string;content?:unknown};if(message?.role!=="assistant")continue;let text="";if(typeof message.content==="string")text=message.content;else if(Array.isArray(message.content))text=message.content.filter((part):part is {type:string;text:string}=>Boolean(part)&&typeof part==="object"&&(part as any).type==="text"&&typeof (part as any).text==="string").map((part)=>part.text).join("\n");text=text.trim();while(text&&new TextEncoder().encode(text).byteLength>16*1024)text=text.slice(0,Math.floor(text.length*0.9));return text;}return "";
}

export function deliveryAction(kind: number): "notify" | "abort" | "shutdown" {
  if (kind === 1) return "notify";
  if (kind === 2) return "abort";
  if (kind === 3) return "shutdown";
  throw new Error("unsupported typed delivery kind");
}
