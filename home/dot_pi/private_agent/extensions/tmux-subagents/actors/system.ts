import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { RendererIpcServer } from "../adapters/ipc-server.ts";
import { DiagnosticJournal } from "../adapters/diagnostic-journal.ts";
import { SubagentsRpcClient, type CompatiblePing } from "../adapters/pi-subagents-rpc.ts";
import { PrivateViewStore, type PaneIdentity, type ViewBinding, type ViewTicket } from "../adapters/store.ts";
import { assertSamePane, socketFromTmuxEnvironment, TmuxController } from "../adapters/tmux.ts";
import type { RuntimeAttestation } from "../adapters/runtime-attestation.ts";
import { requireVisibleIdentity } from "../actions/authority.ts";
import { DEFAULT_TOPOLOGY_LIMITS } from "../actions/topology.ts";
import { scopeProjection, type Projection } from "../domain/projection.ts";
import { ASYNC_COMPLETE_EVENT, ASYNC_STARTED_EVENT, CHILD_STATUS_EVENT, PROCESS_TERMINAL_EVENT } from "../domain/constants.ts";
import type { ActorEvent, AuthorityIdentity, RendererIntent } from "../protocol/actor-events.ts";
import { createRootActor } from "./root.ts";
import { createDiagnosticsActor } from "./diagnostics.ts";
import { createProductionSupervisorActor } from "./supervisors/production.ts";

export interface SystemConfig { compatiblePiSubagentsVersion: string; rpcTimeoutMs: number; ticketTtlMs: number; projectionIntervalMs: number }
export interface SystemDependencies {
  attestRuntime: () => Promise<RuntimeAttestation>;
  installedPiSubagentsVersion?: () => Promise<string | undefined>;
  now?: () => number;
  privateRoot?: () => string;
  createStore?: (root: string, ownerPiSessionId: string, generation: string) => PrivateViewStore;
  createDiagnosticJournal?: (generationRoot: string, generation: string) => DiagnosticJournal;
  createIpcServer?: (...args: ConstructorParameters<typeof RendererIpcServer>) => RendererIpcServer;
  createRootActor?: typeof createRootActor;
  createProductionSupervisor?: typeof createProductionSupervisorActor;
}
export interface ActiveSystem {
  context: ExtensionContext; generation: string; store: PrivateViewStore; rpc: SubagentsRpcClient;
  tickets: Map<string, ViewTicket>; bindings: Map<string, ViewBinding>; disposers: Array<() => void>;
  reaping: boolean; disposed: boolean; ping: CompatiblePing; runtime: RuntimeAttestation;
  projectionIntervalMs: number; ipc: RendererIpcServer; rootActor: ReturnType<typeof createRootActor>;
  effectSupervisor?: ReturnType<typeof createProductionSupervisorActor>;
  latestProjection?: Projection; requestConnections: Map<string, string>; closingBindings: Set<string>;
  rendererConnections: Map<string, string>;
  diagnostics: ReturnType<typeof createDiagnosticsActor>;
  cleanup: CleanupTransaction;
  pendingOperations: Set<Promise<void>>;
  operationFailures: Error[];
}

export function systemSessionId(ctx: ExtensionContext): string {
  const id = ctx.sessionManager.getSessionId(); if (!id) throw new Error("tmux-subagents requires a persistent Pi session identity"); return id;
}
export function defaultPrivateRoot(): string { const scope = typeof process.getuid === "function" ? String(process.getuid()) : os.userInfo().username; return path.join(os.tmpdir(), `pi-tmux-subagents-${scope}`); }
function observe(state: ActiveSystem, event: Parameters<ActiveSystem["diagnostics"]["record"]>[0]): void { void state.diagnostics.record(event).catch(() => {}); }
export async function installedPiSubagentsVersion(): Promise<string | undefined> {
  try { const manifest = JSON.parse(await readFile(path.join(process.env.PI_AGENT_DIR ?? path.join(os.homedir(), ".pi", "agent"), "npm", "node_modules", "pi-subagents", "package.json"), "utf8")); return typeof manifest.version === "string" ? manifest.version : undefined; } catch { return undefined; }
}
function quote(value: string): string { return `'${value.replaceAll("'", `'"'"'`)}'`; }
export function launcherCommandPath(ticketPath: string, runtime: Pick<RuntimeAttestation, "nodePath" | "rendererPath">): string {
  return `${quote(path.join(os.homedir(), ".local", "bin", "workstation-tmux-subagents"))} ${quote(runtime.nodePath)} ${quote(runtime.rendererPath)} ${quote(ticketPath)}`;
}
export function launcherCommand(ticket: ViewTicket, runtime: Pick<RuntimeAttestation, "nodePath" | "rendererPath">): string { return launcherCommandPath(path.join(path.dirname(ticket.claimPath), `${ticket.ticketId}.json`), runtime); }

async function publishProjection(state: ActiveSystem, projection: Projection): Promise<void> {
  if (state.disposed) return; state.latestProjection = projection; const snapshot = state.rootActor.getSnapshot(); const health = { root: String(snapshot.value), ...snapshot.context.supervisorHealth };
  for (const ticket of state.tickets.values()) { const scoped = scopeProjection(projection, ticket.runId, ticket.childId); await state.store.writeProjection(ticket, scoped); state.ipc.publish(ticket.ticketId, scoped, { supervisors: health }); }
  for (const binding of state.bindings.values()) { const scoped = scopeProjection(projection, binding.runId, binding.childId); await state.store.writeProjectionPath(binding.projectionPath, scoped); state.ipc.publish(binding.bindingId, scoped, { supervisors: health }); }
}
export function refreshSystem(state: ActiveSystem, source = "extension"): void { if (!state.disposed) state.rootActor.send({ type: "AUTHORITY.HINT", source }); }
function rendererTarget(state: ActiveSystem, connectionId: string) {
  const bindingId = state.ipc.bindingFor(connectionId); if (!bindingId) return undefined;
  return state.bindings.get(bindingId) ?? (() => { const ticket = state.tickets.get(bindingId); return ticket ? { bindingId, runId: ticket.runId, ...(ticket.childId ? { childId: ticket.childId } : {}) } : undefined; })();
}
function trackOperation(state: ActiveSystem, operation: Promise<void>): void {
  state.pendingOperations.add(operation); void operation.catch((error) => state.operationFailures.push(cleanupError(error))).finally(() => state.pendingOperations.delete(operation));
}
export function handleRendererEvent(state: ActiveSystem, event: ActorEvent): void {
  if (event.type === "RENDER.CONNECTED") { state.rendererConnections.set(event.bindingId, event.connectionId); observe(state, { type: "DIAGNOSTIC.RENDERER", category: "ipc", severity: "info", phase: "renderer-authenticated", status: "success", bindingId: event.bindingId }); }
  if (event.type === "RENDER.DISCONNECTED" && state.rendererConnections.get(event.bindingId) === event.connectionId) { state.rendererConnections.delete(event.bindingId); observe(state, { type: "DIAGNOSTIC.RENDERER", category: "ipc", severity: "warning", phase: "renderer-disconnected", status: "exit", bindingId: event.bindingId }); }
  state.rootActor.send(event); if (event.type !== "RENDER.INPUT") return;
  const target = rendererTarget(state, event.connectionId); if (!target) { state.ipc.send(event.connectionId, { type: "result", requestId: randomUUID(), ok: false, message: "view binding is unavailable" }); return; }
  const intent: RendererIntent = event.intent; if (intent.kind === "refresh") { refreshSystem(state, "renderer"); return; }
  if (intent.kind === "detach") {
    const operation = (async () => {
      try { await detachView(state, target.bindingId); await state.diagnostics.record({ type: "DIAGNOSTIC.RENDERER", category: "tmux", severity: "info", phase: "detach", status: "success", bindingId: target.bindingId }); }
      catch (error) { try { await state.diagnostics.record({ type: "DIAGNOSTIC.RENDERER", category: "tmux", severity: "error", phase: "detach", status: "failure", bindingId: target.bindingId, error }); } catch (persistence) { throw new AggregateError([error, persistence], "detach and durable outcome persistence failed"); } throw error; }
    })(); trackOperation(state, operation); return;
  }
  if (intent.kind === "select") { if (intent.identity) state.rootActor.send({ type: "SELECTION.CHANGED", connectionId: event.connectionId, identity: intent.identity }); return; }
  const identity: AuthorityIdentity = intent.identity ?? { runId: target.runId, ...(target.childId ? { childId: target.childId } : {}) };
  if (identity.runId !== target.runId || (target.childId && identity.childId !== target.childId)) { state.ipc.send(event.connectionId, { type: "result", requestId: randomUUID(), ok: false, message: "selected identity is outside this view" }); return; }
  try { if (state.latestProjection) requireVisibleIdentity(state.latestProjection, identity); } catch (error) { state.ipc.send(event.connectionId, { type: "result", requestId: randomUUID(), ok: false, message: error instanceof Error ? error.message : String(error) }); return; }
  const requestId = randomUUID(); state.requestConnections.set(requestId, event.connectionId);
  const operation = intent.kind === "steer" ? "steer" : intent.kind === "interrupt" ? "interrupt" : intent.kind === "stop" ? "stop" : "resume";
  state.rootActor.send({ type: "CONTROL.REQUEST", requestId, identity, operation, ...(intent.kind === "steer" || intent.kind === "resume" ? { text: intent.text } : {}), ...(intent.kind === "interrupt" || intent.kind === "stop" || intent.kind === "resume" ? { confirmed: intent.confirmed } : {}) });
}
async function topologyEffect<T>(state: ActiveSystem, operation: () => Promise<T>): Promise<T> {
  if (!state.effectSupervisor) throw new Error("tmux topology supervisor is unavailable");
  try { return await state.effectSupervisor.executeTopology(operation); }
  catch (error) { observe(state, { type: "DIAGNOSTIC.TOPOLOGY", category: "topology", severity: "error", phase: "topology-operation", status: "failure", error }); throw error; }
}
function rendererChildId(bindingId: string): string { return `renderer:${bindingId}`; }
function stopRendererChild(state: ActiveSystem, bindingId: string): void { state.effectSupervisor?.removeRenderer(rendererChildId(bindingId)); }
async function detachView(state: ActiveSystem, bindingId: string): Promise<void> {
  state.closingBindings.add(bindingId); stopRendererChild(state, bindingId);
  const ticket = state.tickets.get(bindingId); if (ticket) { await closeTicket(state, ticket, true, false); return; }
  const binding = state.bindings.get(bindingId); if (!binding) return;
  if (binding.created) await topologyEffect(state, () => new TmuxController(binding.pane.socketPath).closeCreated(binding)); else await state.store.closeProjection(binding.projectionPath);
  await state.store.removeBinding(bindingId); state.bindings.delete(bindingId); state.rendererConnections.delete(bindingId); state.ipc.revoke(bindingId); state.rootActor.send({ type: "VIEW.REMOVED", bindingId });
}
function pendingBinding(ticket: ViewTicket): ViewBinding {
  if (!ticket.created || !ticket.expectedPane) throw new Error("ticket is not an exact created-pane ticket");
  return { schemaVersion: 1, bindingId: ticket.ticketId, generation: ticket.generation, ownerPiSessionId: ticket.ownerPiSessionId, runId: ticket.runId, ...(ticket.childId ? { childId: ticket.childId } : {}), created: true, projectionPath: ticket.projectionPath, pane: ticket.expectedPane, createdAt: ticket.issuedAt };
}
async function closeTicket(state: ActiveSystem, ticket: ViewTicket, removeProjection: boolean, removeRenderer = true): Promise<void> {
  if (removeRenderer) stopRendererChild(state, ticket.ticketId);
  if (ticket.created && ticket.expectedPane) await new TmuxController(ticket.expectedPane.socketPath).closeCreated(pendingBinding(ticket)); else await state.store.closeProjection(ticket.projectionPath);
  await state.store.removeTicket(ticket, removeProjection); state.ipc.revoke(ticket.ticketId); state.tickets.delete(ticket.ticketId); state.rendererConnections.delete(ticket.ticketId); state.rootActor.send({ type: "VIEW.REMOVED", bindingId: ticket.ticketId });
}
async function reapExpired(state: ActiveSystem, now: number): Promise<void> { if (state.disposed || state.reaping) return; state.reaping = true; try { for (const ticket of await state.store.expiredTickets(now)) await closeTicket(state, ticket, true); } finally { state.reaping = false; } }
function pause(delayMs: number, signal?: AbortSignal): Promise<void> {
  if (signal?.aborted) return Promise.reject(signal.reason ?? new Error("renderer lifecycle stopped"));
  return new Promise((resolve, reject) => {
    const onAbort = () => { clearTimeout(timer); reject(signal?.reason ?? new Error("renderer lifecycle stopped")); };
    const timer = setTimeout(() => { signal?.removeEventListener("abort", onAbort); resolve(); }, delayMs); timer.unref?.();
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}
async function claimTicket(state: ActiveSystem, ticket: ViewTicket): Promise<ViewBinding> {
  const result = await state.store.consumeClaim(ticket.ticketId); const socket = socketFromTmuxEnvironment(result.claim.tmux); const pane = await new TmuxController(socket).inspectPane(result.claim.paneId);
  if (ticket.created) { if (!ticket.expectedPane) throw new Error("created ticket lost its expected pane identity"); assertSamePane(pane, ticket.expectedPane); }
  const binding: ViewBinding = { schemaVersion: 1, bindingId: ticket.ticketId, generation: state.generation, ownerPiSessionId: systemSessionId(state.context), runId: ticket.runId, ...(ticket.childId ? { childId: ticket.childId } : {}), created: ticket.created, projectionPath: ticket.projectionPath, pane, createdAt: Date.now() };
  await state.store.writeBinding(binding); await state.store.removeTicket(ticket, false); state.bindings.set(binding.bindingId, binding); state.tickets.delete(ticket.ticketId); state.context.ui.notify(publicPaneClaimMessage(state, binding), "info");
  return binding;
}
export function publicPaneClaimMessage(state: Pick<ActiveSystem, "latestProjection">, binding: Pick<ViewBinding, "runId" | "childId" | "created">): string {
  const fallback = "managed actor";
  const accessMode = binding.created ? "owned pane" : "prepared pane";
  try {
    if (!state.latestProjection) return `tmux-subagents claimed ${accessMode} for ${fallback}`;
    const scoped = scopeProjection(state.latestProjection, binding.runId, binding.childId);
    const run = scoped.runs[0];
    const node = binding.childId ? run?.children?.[0] : run;
    const role = (node as any)?.role ? ` · ${sanitizePublic((node as any).role, 32)}` : "";
    const access = (node as any)?.accessMode ? ` · ${sanitizePublic((node as any).accessMode, 32)}` : "";
    const label = sanitizePublic(node?.label, 64) || fallback;
    const stateText = sanitizePublic(node?.state, 24) || "available";
    return `tmux-subagents claimed ${accessMode} for ${label}${role}${access} — ${stateText}`;
  } catch {
    return `tmux-subagents claimed ${accessMode} for ${fallback}`;
  }
}
function sanitizePublic(value: unknown, max: number): string {
  if (typeof value !== "string") return "";
  const clean = value.replace(/\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))/g, "").replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").replace(/\b(?:run|pane|socket|tty|pid|session|credential|handle|fence|payload|prompt)[-_:=]?[A-Za-z0-9_.:/%-]*/gi, "[redacted]").trim();
  return clean.length > max ? `${clean.slice(0, Math.max(0, max - 1))}…` : clean;
}
async function monitorRendererBoundary(state: ActiveSystem, binding: ViewBinding, signal: AbortSignal): Promise<void> {
  const startedAt = Date.now(); let connectedAt: number | undefined; let disconnectedAt: number | undefined;
  while (!signal.aborted) {
    assertSamePane(await new TmuxController(binding.pane.socketPath).inspectPane(binding.pane.paneId), binding.pane);
    const connected = state.rendererConnections.has(binding.bindingId);
    if (connected) { connectedAt ??= Date.now(); disconnectedAt = undefined; }
    else if (connectedAt) { disconnectedAt ??= Date.now(); if (Date.now() - disconnectedAt > 5_000) throw new Error(`authenticated renderer IPC disconnected for ${binding.bindingId}`); }
    else if (Date.now() - startedAt > 10_000) throw new Error(`renderer ${binding.bindingId} did not authenticate`);
    await pause(Math.min(250, state.projectionIntervalMs), signal);
  }
}
async function cleanupLifecycleRecords(state: ActiveSystem, bindingId: string, created: boolean): Promise<void> {
  const binding = state.bindings.get(bindingId); const ticket = state.tickets.get(bindingId);
  if (created) {
    const owned = binding ?? (ticket?.expectedPane ? pendingBinding(ticket) : undefined);
    if (owned) await new TmuxController(owned.pane.socketPath).closeCreated(owned);
  } else {
    const projectionPath = binding?.projectionPath ?? ticket?.projectionPath;
    if (projectionPath) await state.store.closeProjection(projectionPath);
  }
  if (binding) await state.store.removeBinding(bindingId);
  if (ticket) await state.store.removeTicket(ticket, true);
  state.bindings.delete(bindingId); state.tickets.delete(bindingId); state.rendererConnections.delete(bindingId); state.ipc.revoke(bindingId);
}
function superviseAdoptedBinding(state: ActiveSystem, binding: ViewBinding): void {
  const childId = rendererChildId(binding.bindingId); if (!state.effectSupervisor || state.effectSupervisor.rendererState(childId) !== "missing") return;
  const delivery = state.effectSupervisor.addRenderer({ childId, restart: "temporary", run: async (signal) => {
    observe(state, { type: "DIAGNOSTIC.RENDERER", category: "renderer", severity: "info", phase: "adopted-renderer-monitor", status: "start", bindingId: binding.bindingId, actorId: childId });
    try { await monitorRendererBoundary(state, binding, signal); }
    catch (error) { observe(state, { type: "DIAGNOSTIC.RENDERER", category: "renderer", severity: "error", phase: "adopted-renderer-monitor", status: "failure", bindingId: binding.bindingId, actorId: childId, error }); throw error; }
    finally {
      await cleanupLifecycleRecords(state, binding.bindingId, false);
      if (!state.disposed && !state.closingBindings.has(binding.bindingId)) state.rootActor.send({ type: "VIEW.REMOVED", bindingId: binding.bindingId });
    }
  } });
  if (!delivery.delivered) throw new Error(delivery.reason);
}
async function reconcileClaims(state: ActiveSystem): Promise<void> {
  if (state.disposed) return;
  for (const ticket of [...state.tickets.values()].filter((candidate) => !candidate.created)) { let consumed = false; try {
    const binding = await claimTicket(state, ticket); consumed = true; superviseAdoptedBinding(state, binding);
  } catch (error) { const message = error instanceof Error ? error.message : String(error); if (/ENOENT|no such file/.test(message) && !consumed) continue; observe(state, { type: "DIAGNOSTIC.TOPOLOGY", category: "topology", severity: "error", phase: "topology-operation", status: "failure", bindingId: ticket.ticketId, error }); if (consumed) await cleanupLifecycleRecords(state, ticket.ticketId, false); throw error; } }
}
async function reapPriorGenerations(store: PrivateViewStore, graceMs: number, diagnostics: ActiveSystem["diagnostics"]): Promise<void> {
  for (const prior of await store.priorGenerations()) {
    const lease = await prior.reapLease(); if (lease.status !== "stale") throw new Error(`${lease.status.toUpperCase()}_GENERATION: ${lease.reason}`);
    await diagnostics.record({ type: "DIAGNOSTIC.LIFECYCLE", category: "generation", severity: "info", phase: "prior-generation-reap", status: "start", metadata: { state: "prior" } });
    for (const ticket of await prior.allTickets()) { if (ticket.created && ticket.expectedPane) await new TmuxController(ticket.expectedPane.socketPath).closeCreated(pendingBinding(ticket)); else await prior.closeProjection(ticket.projectionPath); await prior.removeTicket(ticket, false); }
    for (const binding of await prior.allBindings()) { if (binding.created) await new TmuxController(binding.pane.socketPath).closeCreated(binding); else await prior.closeProjection(binding.projectionPath); await prior.removeBinding(binding.bindingId); }
    await new Promise((resolve) => setTimeout(resolve, Math.min(1500, graceMs + 100))); await prior.removeStaleGeneration(lease.ownerToken, lease.processStartIdentity);
    await diagnostics.record({ type: "DIAGNOSTIC.LIFECYCLE", category: "generation", severity: "info", phase: "prior-generation-reap", status: "success", metadata: { state: "removed" } });
  }
}

interface CleanupResources {
  store: PrivateViewStore;
  diagnostics?: ReturnType<typeof createDiagnosticsActor>;
  ipc?: RendererIpcServer;
  rootActor?: ReturnType<typeof createRootActor>;
  effectSupervisor?: ReturnType<typeof createProductionSupervisorActor>;
  state?: ActiveSystem;
}
interface CleanupTransaction { resources: CleanupResources; completed: Set<string>; running?: Promise<void> }
function cleanupError(error: unknown): Error { return error instanceof Error ? error : new Error(String(error)); }
async function cleanupTransaction(transaction: CleanupTransaction, cause?: unknown): Promise<void> {
  if (transaction.running) return transaction.running;
  transaction.running = (async () => {
    const { resources, completed } = transaction; const failures: Error[] = cause === undefined ? [] : [cleanupError(cause)];
    const attempt = async (name: string, operation: (() => void | Promise<void>) | undefined) => {
      if (!operation || completed.has(name)) return; try { await operation(); completed.add(name); } catch (error) { failures.push(cleanupError(error)); }
    };
    const state = resources.state; if (state) {
      state.disposed = true;
      await attempt("dispose-start", resources.diagnostics ? () => resources.diagnostics!.record({ type: "DIAGNOSTIC.LIFECYCLE", category: "generation", severity: "info", phase: "generation-dispose", status: "start" }).then(() => undefined) : undefined);
      for (const dispose of state.disposers.splice(0)) await attempt(`disposer:${completed.size}`, dispose);
      await Promise.allSettled([...state.pendingOperations]); for (const failure of state.operationFailures.splice(0)) failures.push(failure);
    }
    await attempt("supervisor-stop", resources.effectSupervisor ? () => resources.effectSupervisor!.stop() : undefined);
    if (state) {
      for (const ticket of [...state.tickets.values()]) await attempt(`ticket:${ticket.ticketId}`, () => closeTicket(state, ticket, false, false));
      for (const binding of [...state.bindings.values()]) await attempt(`binding:${binding.bindingId}`, async () => { if (binding.created) await new TmuxController(binding.pane.socketPath).closeCreated(binding); else await state.store.closeProjection(binding.projectionPath); await state.store.removeBinding(binding.bindingId); state.bindings.delete(binding.bindingId); state.rendererConnections.delete(binding.bindingId); });
    }
    await attempt("root-signal-stop", resources.rootActor ? () => { resources.rootActor!.send({ type: "SUPERVISOR.STOP" }); } : undefined);
    await attempt("root-stop", resources.rootActor ? () => { resources.rootActor!.stop(); } : undefined);
    await attempt("ipc-stop", resources.ipc ? () => resources.ipc!.stop() : undefined);
    if (resources.diagnostics && !completed.has("diagnostics-stop")) {
      const status = failures.length ? "failure" : "success"; await attempt(`dispose-${status}`, () => resources.diagnostics!.record({ type: "DIAGNOSTIC.LIFECYCLE", category: "generation", severity: failures.length ? "error" : "info", phase: "generation-dispose", status, ...(failures.length ? { error: failures[0], metadata: { count: failures.length } } : {}) }).then(() => undefined));
    }
    await attempt("diagnostics-stop", resources.diagnostics ? () => resources.diagnostics!.stop() : undefined);
    await attempt("generation-remove", () => resources.store.removeOwnedGeneration());
    if (!completed.has("generation-remove")) await attempt("lease-release", () => resources.store.releaseLease());
    if (failures.length) throw new AggregateError(failures, "tmux-subagents generation cleanup was incomplete");
  })();
  try { await transaction.running; } finally { transaction.running = undefined; }
}

export async function initializeSystem(pi: ExtensionAPI, ctx: ExtensionContext, config: SystemConfig, dependencies: SystemDependencies): Promise<ActiveSystem> {
  const version = await (dependencies.installedPiSubagentsVersion ?? installedPiSubagentsVersion)(); if (version !== config.compatiblePiSubagentsVersion) throw new Error(`pi-subagents ${version ?? "missing"} is incompatible; expected ${config.compatiblePiSubagentsVersion}`);
  const runtime = await dependencies.attestRuntime(); const generation = randomUUID(); const store = (dependencies.createStore ?? ((root, session, id) => new PrivateViewStore(root, session, id)))(dependencies.privateRoot?.() ?? defaultPrivateRoot(), systemSessionId(ctx), generation);
  const cleanup: CleanupTransaction = { resources: { store }, completed: new Set() }; let state!: ActiveSystem; let diagnostics: ReturnType<typeof createDiagnosticsActor> | undefined; let effectSupervisor: ReturnType<typeof createProductionSupervisorActor> | undefined;
  try {
    await store.initialize(); const journal = (dependencies.createDiagnosticJournal ?? ((root, id) => new DiagnosticJournal(root, id)))(store.generationRoot, generation); diagnostics = createDiagnosticsActor(journal); cleanup.resources.diagnostics = diagnostics; diagnostics.start();
    await diagnostics.record({ type: "DIAGNOSTIC.LIFECYCLE", category: "generation", severity: "info", phase: "generation-initialize", status: "start", actorId: "root" });
    const rpc = new SubagentsRpcClient(pi.events, config.rpcTimeoutMs, (event) => { void diagnostics!.record({ type: "DIAGNOSTIC.RPC", category: "rpc", severity: event.status === "failure" ? "error" : "debug", phase: `rpc-${event.method}`, status: event.status, requestId: event.requestId, ...(event.error ? { error: event.error } : {}), metadata: { method: event.method } }).catch(() => {}); });
    const ping = await rpc.ping();
    const ipc = (dependencies.createIpcServer ?? ((...args) => new RendererIpcServer(...args)))(store.generationRoot, generation, (event) => { if (state) handleRendererEvent(state, event); }, (error) => { void diagnostics!.record({ type: "DIAGNOSTIC.RENDERER", category: "ipc", severity: "error", phase: "ipc-server", status: "failure", error }).catch(() => {}); effectSupervisor?.send({ type: "CHILD.FAILED", childId: "renderer-ipc", reason: error.message, abnormal: true }); }, (event) => { void diagnostics!.record({ type: "DIAGNOSTIC.RENDERER", category: "ipc", severity: event.kind === "rate-limit" ? "warning" : "error", phase: `ipc-${event.kind}`, status: "failure", ...(event.bindingId ? { bindingId: event.bindingId } : {}), error: event.error }).catch(() => {}); }); cleanup.resources.ipc = ipc;
    const rootActor = (dependencies.createRootActor ?? createRootActor)({ sessionId: systemSessionId(ctx), generation, rpc,
      onProjection: (projection) => { effectSupervisor?.send({ type: "PROJECTION.PUBLISH", projection }); },
      onControlResult: (result) => { if (!state) return; const connectionId = state.requestConnections.get(result.requestId); if (connectionId) state.ipc.send(connectionId, { type: "result", requestId: result.requestId, ok: result.ok, message: result.message }); state.requestConnections.delete(result.requestId); },
      onSupervisorReceipt: (receipt) => { if (state) { void state.store.writeSupervisorReceipt(receipt).catch((error) => ctx.ui.notify(error instanceof Error ? error.message : String(error), "warning")); observe(state, { type: "DIAGNOSTIC.SUPERVISOR", category: "supervisor", severity: receipt.decision === "circuit-open" ? "error" : "warning", phase: "root-supervisor-receipt", status: receipt.decision === "circuit-open" ? "circuit-open" : "restart", actorId: receipt.supervisorId, receiptId: `${receipt.supervisorId}:${receipt.childId}:${receipt.restartAttempt}`, error: receipt.reason, metadata: { decision: receipt.decision, restartAttempt: receipt.restartAttempt } }); } },
    }, (inspection) => { if (inspection.type === "@xstate.actor") void diagnostics!.record({ type: "DIAGNOSTIC.LIFECYCLE", category: "lifecycle", severity: "debug", phase: "xstate-actor", status: "checkpoint", actorId: inspection.actorRef.id }).catch(() => {}); }); cleanup.resources.rootActor = rootActor;
    state = { context: ctx, generation, store, rpc, tickets: new Map(), bindings: new Map(), disposers: [], reaping: false, disposed: false, ping, runtime, projectionIntervalMs: config.projectionIntervalMs, ipc, rootActor, requestConnections: new Map(), closingBindings: new Set(), rendererConnections: new Map(), diagnostics, cleanup, pendingOperations: new Set(), operationFailures: [] }; cleanup.resources.state = state;
    let ipcReadyResolve!: () => void; let ipcReadyReject!: (error: unknown) => void; const ipcReady = new Promise<void>((resolve, reject) => { ipcReadyResolve = resolve; ipcReadyReject = reject; }); let priorReaped = false; let systemReady = false;
    effectSupervisor = (dependencies.createProductionSupervisor ?? createProductionSupervisorActor)({
      intervalMs: config.projectionIntervalMs,
      startIpc: async () => { try { await ipc.start(); ipcReadyResolve(); } catch (error) { ipcReadyReject(error); throw error; } }, stopIpc: () => ipc.stop(),
      reconcile: async () => { if (!systemReady) return; if (!priorReaped) { await reapPriorGenerations(store, config.projectionIntervalMs, diagnostics!); priorReaped = true; } await reconcileClaims(state); await reapExpired(state, dependencies.now?.() ?? Date.now()); refreshSystem(state, "production-reconciliation"); },
      publishProjection: (projection) => publishProjection(state, projection),
      receipt: (receipt) => { observe(state, { type: "DIAGNOSTIC.SUPERVISOR", category: "supervisor", severity: receipt.decision === "circuit-open" ? "error" : "warning", phase: "production-supervisor-receipt", status: receipt.decision === "circuit-open" ? "circuit-open" : "restart", actorId: receipt.supervisorId, receiptId: `${receipt.supervisorId}:${receipt.childId}:${receipt.restartAttempt}`, error: receipt.reason, metadata: { decision: receipt.decision, restartAttempt: receipt.restartAttempt, abnormal: receipt.abnormal } }); rootActor.send({ type: "SUPERVISOR.RECEIPT", supervisorId: receipt.supervisorId, childId: receipt.childId, decision: receipt.decision, reason: receipt.reason, at: receipt.occurredAt, restartAttempt: receipt.restartAttempt }); },
      escalate: (receipt) => { observe(state, { type: "DIAGNOSTIC.SUPERVISOR", category: "supervisor", severity: "error", phase: "production-supervisor-escalation", status: "circuit-open", actorId: receipt.supervisorId, error: receipt.reason }); rootActor.send({ type: "CHILD.FAILED", childId: receipt.childId, reason: receipt.reason, abnormal: true, at: receipt.occurredAt }); },
    }); cleanup.resources.effectSupervisor = effectSupervisor; state.effectSupervisor = effectSupervisor; effectSupervisor.start();
    await ipcReady; rootActor.start(); await diagnostics.record({ type: "DIAGNOSTIC.LIFECYCLE", category: "lifecycle", severity: "info", phase: "system-ready", status: "success", actorId: rootActor.id }); systemReady = true;
    for (const event of [ASYNC_STARTED_EVENT, ASYNC_COMPLETE_EVENT, CHILD_STATUS_EVENT, PROCESS_TERMINAL_EVENT]) { const disposer = pi.events.on(event, () => refreshSystem(state, event)); if (typeof disposer === "function") state.disposers.push(disposer); }
    return state;
  } catch (error) { await cleanupTransaction(cleanup, error); throw error; }
}

async function runCreatedRendererLifecycle(state: ActiveSystem, ctx: ExtensionContext, bindingId: string, runId: string, childId: string | undefined, ticketTtlMs: number, signal: AbortSignal, onStarted: (message: string) => void): Promise<void> {
  let ticket: ViewTicket | undefined; let pane: PaneIdentity | undefined;
  observe(state, { type: "DIAGNOSTIC.RENDERER", category: "renderer", severity: "info", phase: "created-renderer-lifecycle", status: "start", bindingId, actorId: rendererChildId(bindingId) });
  try {
    if (!process.env.TMUX) throw new Error("cannot create a pane outside tmux");
    const projection = await state.rpc.status(); const scoped = scopeProjection(projection, runId, childId);
    pane = await topologyEffect(state, () => new TmuxController(socketFromTmuxEnvironment(process.env.TMUX!)).openOwnedPane({ cwd: ctx.cwd, command: launcherCommandPath(state.store.ticketPath(bindingId), state.runtime), owner: state.generation, windowName: "subagents", ...DEFAULT_TOPOLOGY_LIMITS }));
    if (signal.aborted) throw signal.reason ?? new Error("renderer lifecycle stopped");
    ticket = await state.store.createTicket({ ticketId: bindingId, runId, childId, created: true, expectedPane: pane, rendererSocketPath: state.ipc.socketPath, nodePath: state.runtime.nodePath, rendererPath: state.runtime.rendererPath, ttlMs: ticketTtlMs });
    state.tickets.set(bindingId, ticket); state.ipc.register({ ticketId: bindingId, generation: ticket.generation, nonce: ticket.nonce, bindingId }); await state.store.writeProjection(ticket, scoped);
    await topologyEffect(state, () => new TmuxController(pane!.socketPath).focusPane(pane!));
    let binding: ViewBinding | undefined;
    while (!signal.aborted && Date.now() <= ticket.expiresAt) {
      try { binding = await claimTicket(state, ticket); break; }
      catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        if (!/ENOENT|no such file/.test(message)) throw error;
        assertSamePane(await new TmuxController(pane.socketPath).inspectPane(pane.paneId), pane); await pause(50, signal);
      }
    }
    if (!binding) throw new Error(`renderer ${bindingId} did not claim its ticket`);
    while (!signal.aborted && !state.rendererConnections.has(bindingId)) {
      assertSamePane(await new TmuxController(binding.pane.socketPath).inspectPane(binding.pane.paneId), binding.pane);
      if (Date.now() > ticket.expiresAt) throw new Error(`renderer ${bindingId} did not authenticate`);
      await pause(50, signal);
    }
    onStarted(publicPaneClaimMessage(state, binding));
    observe(state, { type: "DIAGNOSTIC.RENDERER", category: "renderer", severity: "info", phase: "created-renderer-authenticated", status: "success", bindingId, actorId: rendererChildId(bindingId) });
    await monitorRendererBoundary(state, binding, signal);
  } catch (error) {
    observe(state, { type: "DIAGNOSTIC.RENDERER", category: "renderer", severity: signal.aborted ? "info" : "error", phase: "created-renderer-lifecycle", status: signal.aborted ? "exit" : "failure", bindingId, actorId: rendererChildId(bindingId), error });
    throw error;
  } finally {
    await cleanupLifecycleRecords(state, bindingId, true);
  }
}

export async function disposeSystem(state: ActiveSystem | undefined): Promise<void> {
  if (!state) return; await cleanupTransaction(state.cleanup);
}

export async function openView(state: ActiveSystem, ctx: ExtensionContext, runId: string, childId: string | undefined, created: boolean, ticketTtlMs: number): Promise<string> {
  const ticketId = randomUUID(); state.rootActor.send({ type: "VIEW.DESIRED", bindingId: ticketId, identity: { runId, ...(childId ? { childId } : {}) } });
  if (created) {
    if (!state.effectSupervisor) throw new Error("renderer supervisor is unavailable");
    let settled = false; let resolveStarted!: (message: string) => void; let rejectStarted!: (error: Error) => void;
    const started = new Promise<string>((resolve, reject) => { resolveStarted = resolve; rejectStarted = reject; });
    const delivery = state.effectSupervisor.addRenderer({ childId: rendererChildId(ticketId), restart: "permanent", run: async (signal) => {
      try { await runCreatedRendererLifecycle(state, ctx, ticketId, runId, childId, ticketTtlMs, signal, (message) => { if (!settled) { settled = true; resolveStarted(message); } }); }
      catch (error) { if (!settled) { settled = true; rejectStarted(error instanceof Error ? error : new Error(String(error))); } throw error; }
    } });
    if (!delivery.delivered) { state.rootActor.send({ type: "VIEW.REMOVED", bindingId: ticketId }); throw new Error(delivery.reason); }
    const timer = setTimeout(() => { if (!settled) { settled = true; rejectStarted(new Error("renderer lifecycle did not start before its bounded timeout")); } }, Math.min(ticketTtlMs, 15_000)); timer.unref?.();
    try { return await started; }
    catch (error) { stopRendererChild(state, ticketId); await cleanupLifecycleRecords(state, ticketId, true); state.rootActor.send({ type: "VIEW.REMOVED", bindingId: ticketId }); throw error; }
    finally { clearTimeout(timer); }
  }
  try {
    const projection = await state.rpc.status(); const scoped = scopeProjection(projection, runId, childId);
    const ticket = await state.store.createTicket({ ticketId, runId, childId, created: false, rendererSocketPath: state.ipc.socketPath, nodePath: state.runtime.nodePath, rendererPath: state.runtime.rendererPath, ttlMs: ticketTtlMs });
    state.tickets.set(ticket.ticketId, ticket); state.ipc.register({ ticketId: ticket.ticketId, generation: ticket.generation, nonce: ticket.nonce, bindingId: ticket.ticketId }); await state.store.writeProjection(ticket, scoped);
    return `Run this command in the prepared pane:\n${launcherCommand(ticket, state.runtime)}`;
  } catch (error) { const ticket = state.tickets.get(ticketId); if (ticket) await closeTicket(state, ticket, true); state.rootActor.send({ type: "VIEW.REMOVED", bindingId: ticketId }); throw error; }
}
export async function focusView(state: ActiveSystem, bindingId: string): Promise<void> { const binding = state.bindings.get(bindingId); if (!binding) throw new Error(`unknown current-generation binding ${bindingId}`); await topologyEffect(state, () => new TmuxController(binding.pane.socketPath).focusPane(binding.pane)); }
export async function closeView(state: ActiveSystem, bindingId: string): Promise<void> {
  const binding = state.bindings.get(bindingId); if (!binding) throw new Error(`unknown current-generation binding ${bindingId}`);
  state.closingBindings.add(bindingId); stopRendererChild(state, bindingId);
  if (binding.created) await topologyEffect(state, () => new TmuxController(binding.pane.socketPath).closeCreated(binding)); else await state.store.closeProjection(binding.projectionPath);
  await state.store.removeBinding(binding.bindingId); state.bindings.delete(binding.bindingId); state.rendererConnections.delete(bindingId); state.ipc.revoke(bindingId); state.rootActor.send({ type: "VIEW.REMOVED", bindingId });
}
