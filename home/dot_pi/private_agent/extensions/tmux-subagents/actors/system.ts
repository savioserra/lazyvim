import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { RendererIpcServer } from "../adapters/ipc-server.ts";
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
import { createProductionSupervisorActor } from "./supervisors/production.ts";

export interface SystemConfig { compatiblePiSubagentsVersion: string; rpcTimeoutMs: number; ticketTtlMs: number; projectionIntervalMs: number }
export interface SystemDependencies {
  attestRuntime: () => Promise<RuntimeAttestation>;
  installedPiSubagentsVersion?: () => Promise<string | undefined>;
  now?: () => number;
  privateRoot?: () => string;
}
export interface ActiveSystem {
  context: ExtensionContext; generation: string; store: PrivateViewStore; rpc: SubagentsRpcClient;
  tickets: Map<string, ViewTicket>; bindings: Map<string, ViewBinding>; disposers: Array<() => void>;
  reaping: boolean; disposed: boolean; ping: CompatiblePing; runtime: RuntimeAttestation;
  projectionIntervalMs: number; ipc: RendererIpcServer; rootActor: ReturnType<typeof createRootActor>;
  effectSupervisor?: ReturnType<typeof createProductionSupervisorActor>;
  latestProjection?: Projection; requestConnections: Map<string, string>; closingBindings: Set<string>;
  rendererConnections: Map<string, string>;
}

export function systemSessionId(ctx: ExtensionContext): string {
  const id = ctx.sessionManager.getSessionId(); if (!id) throw new Error("tmux-subagents requires a persistent Pi session identity"); return id;
}
function defaultPrivateRoot(): string { const scope = typeof process.getuid === "function" ? String(process.getuid()) : os.userInfo().username; return path.join(os.tmpdir(), `pi-tmux-subagents-${scope}`); }
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
function handleRendererEvent(state: ActiveSystem, event: ActorEvent): void {
  if (event.type === "RENDER.CONNECTED") state.rendererConnections.set(event.bindingId, event.connectionId);
  if (event.type === "RENDER.DISCONNECTED" && state.rendererConnections.get(event.bindingId) === event.connectionId) state.rendererConnections.delete(event.bindingId);
  state.rootActor.send(event); if (event.type !== "RENDER.INPUT") return;
  const target = rendererTarget(state, event.connectionId); if (!target) { state.ipc.send(event.connectionId, { type: "result", requestId: randomUUID(), ok: false, message: "view binding is unavailable" }); return; }
  const intent: RendererIntent = event.intent; if (intent.kind === "refresh") { refreshSystem(state, "renderer"); return; }
  if (intent.kind === "detach") { void detachView(state, target.bindingId); return; }
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
  return state.effectSupervisor.executeTopology(operation);
}
function rendererChildId(bindingId: string): string { return `renderer:${bindingId}`; }
function stopRendererChild(state: ActiveSystem, bindingId: string): void { state.effectSupervisor?.removeRenderer(rendererChildId(bindingId)); }
async function detachView(state: ActiveSystem, bindingId: string): Promise<void> {
  state.closingBindings.add(bindingId); stopRendererChild(state, bindingId);
  const ticket = state.tickets.get(bindingId); if (ticket) { await closeTicket(state, ticket, true, false); return; }
  const binding = state.bindings.get(bindingId); if (!binding) return;
  try { if (binding.created) await topologyEffect(state, () => new TmuxController(binding.pane.socketPath).closeCreated(binding)); else await state.store.closeProjection(binding.projectionPath); } catch {}
  await state.store.removeBinding(bindingId).catch(() => {}); state.bindings.delete(bindingId); state.rendererConnections.delete(bindingId); state.ipc.revoke(bindingId); state.rootActor.send({ type: "VIEW.REMOVED", bindingId });
}
function pendingBinding(ticket: ViewTicket): ViewBinding {
  if (!ticket.created || !ticket.expectedPane) throw new Error("ticket is not an exact created-pane ticket");
  return { schemaVersion: 1, bindingId: ticket.ticketId, generation: ticket.generation, ownerPiSessionId: ticket.ownerPiSessionId, runId: ticket.runId, ...(ticket.childId ? { childId: ticket.childId } : {}), created: true, projectionPath: ticket.projectionPath, pane: ticket.expectedPane, createdAt: ticket.issuedAt };
}
async function closeTicket(state: ActiveSystem, ticket: ViewTicket, removeProjection: boolean, removeRenderer = true): Promise<void> {
  if (removeRenderer) stopRendererChild(state, ticket.ticketId);
  if (ticket.created && ticket.expectedPane) await new TmuxController(ticket.expectedPane.socketPath).closeCreated(pendingBinding(ticket)).catch(() => {}); else await state.store.closeProjection(ticket.projectionPath).catch(() => {});
  await state.store.removeTicket(ticket, removeProjection).catch(() => {}); state.ipc.revoke(ticket.ticketId); state.tickets.delete(ticket.ticketId); state.rendererConnections.delete(ticket.ticketId); state.rootActor.send({ type: "VIEW.REMOVED", bindingId: ticket.ticketId });
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
  await state.store.writeBinding(binding); await state.store.removeTicket(ticket, false); state.bindings.set(binding.bindingId, binding); state.tickets.delete(ticket.ticketId); state.context.ui.notify(`tmux-subagents claimed ${pane.paneId} for ${ticket.runId}`, "info");
  return binding;
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
    if (owned) await new TmuxController(owned.pane.socketPath).closeCreated(owned).catch(() => {});
  } else {
    const projectionPath = binding?.projectionPath ?? ticket?.projectionPath;
    if (projectionPath) await state.store.closeProjection(projectionPath).catch(() => {});
  }
  if (binding) await state.store.removeBinding(bindingId).catch(() => {});
  if (ticket) await state.store.removeTicket(ticket, true).catch(() => {});
  state.bindings.delete(bindingId); state.tickets.delete(bindingId); state.rendererConnections.delete(bindingId); state.ipc.revoke(bindingId);
}
function superviseAdoptedBinding(state: ActiveSystem, binding: ViewBinding): void {
  const childId = rendererChildId(binding.bindingId); if (!state.effectSupervisor || state.effectSupervisor.rendererState(childId) !== "missing") return;
  const delivery = state.effectSupervisor.addRenderer({ childId, restart: "temporary", run: async (signal) => {
    try { await monitorRendererBoundary(state, binding, signal); }
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
  } catch (error) { const message = error instanceof Error ? error.message : String(error); if (consumed) await cleanupLifecycleRecords(state, ticket.ticketId, false); if (!message.includes("ENOENT") && !message.includes("no such file")) state.context.ui.notify(message, "warning"); } }
}
async function reapPriorGenerations(store: PrivateViewStore, graceMs: number): Promise<void> {
  for (const prior of await store.priorGenerations()) {
    for (const ticket of await prior.allTickets()) { if (ticket.created && ticket.expectedPane) await new TmuxController(ticket.expectedPane.socketPath).closeCreated(pendingBinding(ticket)).catch(() => {}); else await prior.closeProjection(ticket.projectionPath).catch(() => {}); await prior.removeTicket(ticket, false).catch(() => {}); }
    for (const binding of await prior.allBindings()) { if (binding.created) await new TmuxController(binding.pane.socketPath).closeCreated(binding).catch(() => {}); else await prior.closeProjection(binding.projectionPath).catch(() => {}); await prior.removeBinding(binding.bindingId).catch(() => {}); }
    await new Promise((resolve) => setTimeout(resolve, Math.min(1500, graceMs + 100))); await prior.removeGeneration();
  }
}

export async function initializeSystem(pi: ExtensionAPI, ctx: ExtensionContext, config: SystemConfig, dependencies: SystemDependencies): Promise<ActiveSystem> {
  const version = await (dependencies.installedPiSubagentsVersion ?? installedPiSubagentsVersion)(); if (version !== config.compatiblePiSubagentsVersion) throw new Error(`pi-subagents ${version ?? "missing"} is incompatible; expected ${config.compatiblePiSubagentsVersion}`);
  const runtime = await dependencies.attestRuntime(); const generation = randomUUID(); const store = new PrivateViewStore(dependencies.privateRoot?.() ?? defaultPrivateRoot(), systemSessionId(ctx), generation);
  await store.initialize(); const rpc = new SubagentsRpcClient(pi.events, config.rpcTimeoutMs); const ping = await rpc.ping(); let state: ActiveSystem; let effectSupervisor: ReturnType<typeof createProductionSupervisorActor> | undefined;
  const ipc = new RendererIpcServer(store.generationRoot, generation, (event) => { if (state) handleRendererEvent(state, event); }, (error) => effectSupervisor?.send({ type: "CHILD.FAILED", childId: "renderer-ipc", reason: error.message, abnormal: true }));
  const rootActor = createRootActor({ sessionId: systemSessionId(ctx), generation, rpc,
    onProjection: (projection) => { effectSupervisor?.send({ type: "PROJECTION.PUBLISH", projection }); },
    onControlResult: (result) => { if (!state) return; const connectionId = state.requestConnections.get(result.requestId); if (connectionId) state.ipc.send(connectionId, { type: "result", requestId: result.requestId, ok: result.ok, message: result.message }); state.requestConnections.delete(result.requestId); },
    onSupervisorReceipt: (receipt) => { if (state) void state.store.writeSupervisorReceipt(receipt).catch((error) => ctx.ui.notify(error instanceof Error ? error.message : String(error), "warning")); },
  });
  state = { context: ctx, generation, store, rpc, tickets: new Map(), bindings: new Map(), disposers: [], reaping: false, disposed: false, ping, runtime, projectionIntervalMs: config.projectionIntervalMs, ipc, rootActor, requestConnections: new Map(), closingBindings: new Set(), rendererConnections: new Map() };
  let ipcReadyResolve!: () => void; let ipcReadyReject!: (error: unknown) => void; const ipcReady = new Promise<void>((resolve, reject) => { ipcReadyResolve = resolve; ipcReadyReject = reject; });
  let priorReaped = false;
  effectSupervisor = createProductionSupervisorActor({
    intervalMs: config.projectionIntervalMs,
    startIpc: async () => { try { await ipc.start(); ipcReadyResolve(); } catch (error) { ipcReadyReject(error); throw error; } },
    stopIpc: () => ipc.stop(),
    reconcile: async () => {
      if (!priorReaped) { await reapPriorGenerations(store, config.projectionIntervalMs); priorReaped = true; }
      await reconcileClaims(state); await reapExpired(state, dependencies.now?.() ?? Date.now()); refreshSystem(state, "production-reconciliation");
    },
    publishProjection: (projection) => publishProjection(state, projection),
    receipt: (receipt) => rootActor.send({ type: "SUPERVISOR.RECEIPT", supervisorId: receipt.supervisorId, childId: receipt.childId, decision: receipt.decision, reason: receipt.reason, at: receipt.occurredAt, restartAttempt: receipt.restartAttempt }),
    escalate: (receipt) => rootActor.send({ type: "CHILD.FAILED", childId: receipt.childId, reason: receipt.reason, abnormal: true, at: receipt.occurredAt }),
  });
  state.effectSupervisor = effectSupervisor; effectSupervisor.start(); await ipcReady; rootActor.start();
  for (const event of [ASYNC_STARTED_EVENT, ASYNC_COMPLETE_EVENT, CHILD_STATUS_EVENT, PROCESS_TERMINAL_EVENT]) { const disposer = pi.events.on(event, () => refreshSystem(state, event)); if (typeof disposer === "function") state.disposers.push(disposer); }
  return state;
}

async function runCreatedRendererLifecycle(state: ActiveSystem, ctx: ExtensionContext, bindingId: string, runId: string, childId: string | undefined, ticketTtlMs: number, signal: AbortSignal, onStarted: (message: string) => void): Promise<void> {
  let ticket: ViewTicket | undefined; let pane: PaneIdentity | undefined;
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
    onStarted(`Created ${binding.pane.paneId}; the interactive renderer is authenticated`);
    await monitorRendererBoundary(state, binding, signal);
  } finally {
    await cleanupLifecycleRecords(state, bindingId, true);
  }
}

export async function disposeSystem(state: ActiveSystem | undefined): Promise<void> {
  if (!state || state.disposed) return; state.disposed = true; for (const dispose of state.disposers.splice(0)) dispose(); state.effectSupervisor?.stop();
  for (const ticket of [...state.tickets.values()]) await closeTicket(state, ticket, false, false);
  for (const binding of [...state.bindings.values()]) { try { if (binding.created) await new TmuxController(binding.pane.socketPath).closeCreated(binding); else await state.store.closeProjection(binding.projectionPath); } catch {} await state.store.removeBinding(binding.bindingId).catch(() => {}); }
  state.tickets.clear(); state.bindings.clear(); state.rendererConnections.clear(); state.rootActor.send({ type: "SUPERVISOR.STOP" }); state.rootActor.stop(); await state.ipc.stop().catch(() => {}); await new Promise((resolve) => setTimeout(resolve, Math.min(1500, state.projectionIntervalMs + 100))); await state.store.removeGeneration().catch(() => {});
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
  if (binding.created) await topologyEffect(state, () => new TmuxController(binding.pane.socketPath).closeCreated(binding)).catch(() => {}); else await state.store.closeProjection(binding.projectionPath);
  await state.store.removeBinding(binding.bindingId); state.bindings.delete(binding.bindingId); state.rendererConnections.delete(bindingId); state.ipc.revoke(bindingId); state.rootActor.send({ type: "VIEW.REMOVED", bindingId });
}
