import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { RendererIpcServer } from "../adapters/ipc-server.ts";
import { scopeProjection, type ProjectionNode } from "../domain/projection.ts";
import type { SubagentsRpcClient } from "../adapters/pi-subagents-rpc.ts";
import { PrivateViewStore, type ViewBinding, type ViewTicket } from "../adapters/store.ts";
import { TmuxController } from "../adapters/tmux.ts";
import type { RuntimeAttestation } from "../adapters/runtime-attestation.ts";
import { createRootActor } from "../actors/root.ts";
import type { FailureReceipt } from "../actors/supervisors/supervisor.ts";
import { createProductionSupervisorActor } from "../actors/supervisors/production.ts";

const execFileAsync = promisify(execFile);
function states(nodes: ProjectionNode[]): unknown { return nodes.map((node) => ({ id: node.id, state: node.state, children: states(node.children ?? []) })); }
function quote(value: string): string { return `'${value.replaceAll("'", `'"'"'`)}'`; }
async function tmux(socket: string, args: string[]): Promise<string> { const result = await execFileAsync("tmux", ["-S", socket, ...args], { timeout: 5000, encoding: "utf8" }); return result.stdout; }
async function until(predicate: () => boolean | Promise<boolean>, message: string) { for (let attempt = 0; attempt < 100; attempt++) { if (await predicate()) return; await new Promise((resolve) => setTimeout(resolve, 50)); } throw new Error(message); }

function ipcClient(socketPath: string) {
  const socket = net.createConnection(socketPath); socket.setEncoding("utf8"); let buffer = ""; const frames: any[] = [];
  socket.on("data", (chunk) => { buffer += chunk; while (buffer.includes("\n")) { const split = buffer.indexOf("\n"); const line = buffer.slice(0, split); buffer = buffer.slice(split + 1); if (line) frames.push(JSON.parse(line)); } });
  return { socket, frames };
}

export async function detachCreatedThroughTopology(
  production: { executeTopology<T>(operation: () => Promise<T>): Promise<T> },
  controller: Pick<TmuxController, "closeCreated">,
  binding: ViewBinding,
): Promise<void> {
  await production.executeTopology(() => controller.closeCreated(binding));
}

export interface SmokeCleanupResources {
  root: string;
  socket?: string;
  tmuxStarted: boolean;
  actor?: { send(event: { type: "SUPERVISOR.STOP" }): unknown; stop(): unknown };
  actorStarted: boolean;
  production?: { stop(): Promise<void> };
  ipc?: { stop(): Promise<void> };
  store?: Pick<PrivateViewStore, "removeOwnedGeneration" | "removeTicket">;
  tickets: Map<string, ViewTicket>;
  removeRoot?: (root: string) => Promise<void>;
  stopTmux?: (socket: string) => Promise<void>;
}
export async function cleanupSmokeResources(resources: SmokeCleanupResources, observe?: (event: { phase: string; status: "start" | "success" | "failure"; error?: unknown; metadata?: Record<string, unknown> }) => Promise<void>): Promise<void> {
  const failures: unknown[] = []; try { await observe?.({ phase: "cleanup", status: "start" }); } catch (error) { failures.push(error); }
  try { await resources.production?.stop(); } catch (error) { failures.push(error); }
  if (resources.actorStarted) {
    try { resources.actor?.send({ type: "SUPERVISOR.STOP" }); } catch (error) { failures.push(error); }
    try { resources.actor?.stop(); } catch (error) { failures.push(error); }
  }
  try { await resources.ipc?.stop(); } catch (error) { failures.push(error); }
  if (resources.tmuxStarted && resources.socket) try { await (resources.stopTmux ?? (async (socket) => { await execFileAsync("tmux", ["-S", socket, "kill-server"], { timeout: 3000 }); }))(resources.socket); } catch (error) { failures.push(error); }
  let generationRemoved = !resources.store;
  if (resources.store) {
    for (const ticket of resources.tickets.values()) try { await resources.store.removeTicket(ticket, true); } catch (error) { failures.push(error); }
    try { await resources.store.removeOwnedGeneration(); generationRemoved = true; } catch (error) { failures.push(error); }
  }
  if (generationRemoved) try { await (resources.removeRoot ?? ((root) => rm(root, { recursive: true, force: false })))(resources.root); } catch (error) { failures.push(error); }
  if (failures.length) { try { await observe?.({ phase: "cleanup", status: "failure", error: failures[0], metadata: { count: failures.length } }); } catch (error) { failures.push(error); } throw new AggregateError(failures, "smoke cleanup was incomplete"); }
  await observe?.({ phase: "cleanup", status: "success" });
}

export async function runSmoke(input: {
  rpc: Pick<SubagentsRpcClient, "status">;
  attestation: RuntimeAttestation;
  ownerPiSessionId: string;
  generation: string;
  home?: string;
  now?: () => number;
  observe?: (event: { phase: string; status: "start" | "success" | "failure" | "checkpoint"; error?: unknown; metadata?: Record<string, unknown> }) => Promise<void>;
  operations?: { temporaryRoot?: () => Promise<string>; project?: typeof scopeProjection };
}): Promise<string> {
  let phase = "runtime-attestation"; let earlyCleanup: (() => Promise<void>) | undefined;
  const mark = async (status: "start" | "success" | "failure" | "checkpoint", error?: unknown, metadata?: Record<string, unknown>) => { await input.observe?.({ phase, status, ...(error ? { error } : {}), ...(metadata ? { metadata } : {}) }); };
  const begin = async (next: string, metadata?: Record<string, unknown>) => { phase = next; await mark("start", undefined, metadata); };
  const done = async (metadata?: Record<string, unknown>) => { await mark("success", undefined, metadata); };
  try {
  await begin("runtime-attestation");
  if (!input.attestation.rendererPath.startsWith(`${input.attestation.root}${path.sep}`)) throw new Error("smoke renderer attestation escaped its package root");
  await done(); await begin("authority-snapshot-precondition");
  const before = await input.rpc.status(); const run = before.runs.find((candidate) => ["complete", "failed", "stopped", "rejected"].includes(candidate.state)) ?? before.runs[0];
  if (!run) throw new Error("smoke requires one visible current-session run; start a trivial async run and invoke smoke while it remains visible");
  await done({ state: run.state });
  const root = await (input.operations?.temporaryRoot ?? (() => mkdtemp(path.join(os.tmpdir(), "tms-"))))(); const socket = path.join(root, "tmux.sock"); const generation = `${input.generation.slice(0, 24)}-smoke`; const tickets = new Map<string, ViewTicket>();
  const cleanupResources: SmokeCleanupResources = { root, socket, tmuxStarted: false, actorStarted: false, tickets }; earlyCleanup = () => cleanupSmokeResources(cleanupResources, input.observe);
  const store = new PrivateViewStore(path.join(root, "p"), input.ownerPiSessionId, generation); cleanupResources.store = store; await store.initialize(); const scoped = (input.operations?.project ?? scopeProjection)(before, run.id);
  const connections = new Map<string, string>(); const controls: any[] = []; const results: any[] = []; const receipts: FailureReceipt[] = []; const launches: Array<{ ticket: ViewTicket; binding: ViewBinding; connectionId?: string; rendered: boolean }> = [];
  const fakeRpc = { status: async () => before, control: async (...args: any[]) => { controls.push(args); return { message: "isolated steer acknowledged", data: {} }; } } as any;
  await begin("isolated-root");
  let actor = createRootActor({ sessionId: input.ownerPiSessionId, generation, rpc: fakeRpc, onProjection: () => {}, onControlResult: (result) => { results.push(result); const connectionId = results.at(-1)?.connectionId ?? controlConnection; if (connectionId) ipc.send(connectionId, { type: "result", requestId: result.requestId, ok: result.ok, message: result.message }); } });
  cleanupResources.actor = actor;
  let controlConnection: string | undefined;
  const ipc = new RendererIpcServer(store.generationRoot, generation, (event) => {
    actor.send(event);
    if (event.type === "RENDER.CONNECTED") { connections.set(event.bindingId, event.connectionId); ipc.publish(event.bindingId, scoped, { supervisors: { smoke: "healthy" } }); if (event.bindingId === "control") controlConnection = event.connectionId; }
    if (event.type === "RENDER.INPUT" && event.intent.kind === "steer") actor.send({ type: "CONTROL.REQUEST", requestId: randomUUID(), identity: { runId: run.id }, operation: "steer", text: event.intent.text });
  }); cleanupResources.ipc = ipc;
  actor.start(); cleanupResources.actorStarted = true; await until(() => actor.getSnapshot().matches("ready"), "smoke fake authority did not become ready"); await done();
  const home = input.home ?? os.homedir(); const launcher = path.join(home, ".local", "bin", "workstation-tmux-subagents"); const controller = new TmuxController(socket);
  await begin("isolated-tmux"); await tmux(socket, ["-f", "/dev/null", "new-session", "-d", "-s", "tmux-subagents-smoke", "sleep 30"]); cleanupResources.tmuxStarted = true; await done();
  await begin("foreign-tuple-capture"); const foreignPaneId = (await tmux(socket, ["display-message", "-p", "-t", "tmux-subagents-smoke:0.0", "#{pane_id}"])).trim();
  const foreignBefore = await controller.inspectPane(foreignPaneId); await done();
  let ipcReadyResolve!: () => void; const ipcReady = new Promise<void>((resolve) => { ipcReadyResolve = resolve; });
  const production = createProductionSupervisorActor({ intervalMs: 25, topologyTimeoutMs: 2_000, startIpc: async () => { await ipc.start(); ipcReadyResolve(); }, stopIpc: () => ipc.stop(), reconcile: async () => {}, publishProjection: async () => {}, receipt: (receipt) => receipts.push(receipt) });
  cleanupResources.production = production; await begin("ipc-start"); production.start(); await ipcReady; await done();
  const rendererLogic = async (signal: AbortSignal) => {
    const ticketId = randomUUID(); const command = `${input.home ? `HOME=${quote(home)} ` : ""}${quote(launcher)} ${quote(input.attestation.nodePath)} ${quote(input.attestation.rendererPath)} ${quote(store.ticketPath(ticketId))}`;
    const pane = await production.executeTopology(() => controller.openOwnedPane({ cwd: root, command, owner: generation, windowName: "smoke", maxPanesPerWindow: 1, maxWindows: 4 }));
    const ticket = await store.createTicket({ ticketId, runId: run.id, created: true, expectedPane: pane, rendererSocketPath: ipc.socketPath, nodePath: input.attestation.nodePath, rendererPath: input.attestation.rendererPath, ttlMs: 30_000, now: input.now?.() });
    tickets.set(ticketId, ticket); ipc.register({ ticketId, generation, nonce: ticket.nonce, bindingId: ticketId }); await store.writeProjection(ticket, scoped);
    await until(async () => { try { await store.consumeClaim(ticketId); return true; } catch (error) { const message = error instanceof Error ? error.message : String(error); if (/ENOENT|no such file/.test(message)) return false; throw error; } }, "renderer did not cooperatively claim its one-use ticket");
    await until(() => connections.has(ticketId), "renderer did not authenticate");
    const binding: ViewBinding = { schemaVersion: 1, bindingId: ticketId, generation, ownerPiSessionId: input.ownerPiSessionId, runId: run.id, created: true, projectionPath: ticket.projectionPath, pane, createdAt: Date.now() };
    const launch = { ticket, binding, connectionId: connections.get(ticketId), rendered: false }; launches.push(launch);
    await until(async () => { const output = await tmux(socket, ["capture-pane", "-p", "-t", pane.paneId]).catch(() => ""); launch.rendered = output.includes(run.label) || output.includes("tmux subagents"); return launch.rendered; }, "Terminal Kit renderer did not render the projection");
    await until(async () => { if (signal.aborted) return true; try { await controller.inspectPane(pane.paneId); return false; } catch { return true; } }, "renderer process did not exit");
    if (!signal.aborted) throw new Error("supervised renderer pane/process exited");
  };
  await begin("renderer-launch-claim-auth-render");
  const delivery = production.addRenderer({ childId: "renderer:smoke-created", restart: "permanent", run: rendererLogic });
  if (!delivery.delivered) throw new Error(delivery.reason);
  try {
    await until(() => launches.length === 1 && launches[0].rendered, "supervised renderer did not start"); await done();
    await begin("renderer-sigkill-observed"); process.kill(launches[0].binding.pane.panePid, "SIGKILL");
    await until(() => receipts.some((receipt) => receipt.childId === "renderer:smoke-created" && receipt.decision === "restart" && receipt.abnormal === true), "production supervisor did not observe real renderer process failure"); await done();
    await begin("renderer-supervised-restart"); await until(() => launches.length === 2 && launches[1].rendered, "supervisor did not restart the real renderer process"); await done();

    await begin("control-acknowledgement"); const controlTicket = await store.createTicket({ ticketId: "control", runId: run.id, created: false, rendererSocketPath: ipc.socketPath, nodePath: input.attestation.nodePath, rendererPath: input.attestation.rendererPath, ttlMs: 30_000 }); ipc.register({ ticketId: "control", generation, nonce: controlTicket.nonce, bindingId: "control" });
    const client = ipcClient(ipc.socketPath); await new Promise((resolve) => client.socket.once("connect", resolve)); client.socket.write(`${JSON.stringify({ version: 1, sequence: 1, type: "authenticate", ticketId: "control", generation, nonce: controlTicket.nonce })}\n`); await until(() => client.frames.some((frame) => frame.type === "authenticated"), "control renderer did not authenticate"); client.socket.write(`${JSON.stringify({ version: 1, sequence: 2, type: "intent", intent: { kind: "steer", text: "smoke steer" } })}\n`); await until(() => client.frames.some((frame) => frame.type === "result" && frame.ok), "steer was not acknowledged through the production actor control path"); if (controls.length !== 1 || controls[0][0] !== "steer" || controls[0][1]?.runId !== run.id || controls[0][2] !== "smoke steer") throw new Error("isolated authority did not receive the exact acknowledged steer"); client.socket.destroy(); await done();

    await begin("stale-generation-rejection"); const stale = ipcClient(ipc.socketPath); await new Promise((resolve) => stale.socket.once("connect", resolve)); stale.socket.write(`${JSON.stringify({ version: 1, sequence: 1, type: "authenticate", ticketId: "control", generation: `${generation}-stale`, nonce: controlTicket.nonce })}\n`); await until(() => stale.frames.some((frame) => frame.type === "fatal"), "stale generation authentication was accepted"); stale.socket.destroy(); await done();
    await begin("detach"); production.removeRenderer("renderer:smoke-created"); await detachCreatedThroughTopology(production, controller, launches[1].binding); ipc.revoke(launches[1].ticket.ticketId); await done();
    await begin("created-pane-absent"); await until(async () => { try { await controller.inspectPane(launches[1].binding.pane.paneId); return false; } catch { return true; } }, "created renderer pane still exists after detach"); await done();
    await begin("foreign-tuple-unchanged"); const foreignAfter = await controller.inspectPane(foreignPaneId); if (JSON.stringify(foreignAfter) !== JSON.stringify(foreignBefore)) throw new Error("smoke changed the foreign seed pane identity tuple"); await done();
    await begin("authority-unchanged"); const after = await input.rpc.status(); if (JSON.stringify(states(before.runs)) !== JSON.stringify(states(after.runs))) throw new Error("smoke changed authoritative managed-run identity or lifecycle state"); await done();
    return `smoke passed: authenticated steer acknowledged, Terminal Kit rendered, real renderer kill restarted by production supervisor, stale generation rejected, created pane absent, foreign pane identity unchanged, authority unchanged`;
  } finally {
    const cleanup = earlyCleanup; earlyCleanup = undefined; if (cleanup) await cleanup();
  }
  } catch (error) {
    let failure: unknown = error; if (earlyCleanup) try { await earlyCleanup(); } catch (cleanup) { failure = new AggregateError([error, cleanup], "smoke operation and cleanup failed"); }
    try { await mark("failure", failure); } catch (persistence) { failure = new AggregateError([failure, persistence], "smoke failure persistence failed"); }
    throw new Error(`smoke phase ${phase} failed: ${failure instanceof Error ? failure.message : String(failure)}`);
  }

}
