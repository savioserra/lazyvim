import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtemp } from "node:fs/promises";
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

export async function runSmoke(input: {
  rpc: Pick<SubagentsRpcClient, "status">;
  attestation: RuntimeAttestation;
  ownerPiSessionId: string;
  generation: string;
  home?: string;
  now?: () => number;
}): Promise<string> {
  if (!input.attestation.rendererPath.startsWith(`${input.attestation.root}${path.sep}`)) throw new Error("smoke renderer attestation escaped its package root");
  const before = await input.rpc.status(); const run = before.runs.find((candidate) => ["complete", "failed", "stopped", "rejected"].includes(candidate.state));
  if (!run) throw new Error("smoke requires one visible terminal current-session run; start a trivial async run and wait for completion first");
  const root = await mkdtemp(path.join(os.tmpdir(), "tms-")); const socket = path.join(root, "tmux.sock"); const generation = `${input.generation.slice(0, 24)}-smoke`;
  const store = new PrivateViewStore(path.join(root, "p"), input.ownerPiSessionId, generation); await store.initialize(); const scoped = scopeProjection(before, run.id);
  const tickets = new Map<string, ViewTicket>(); const connections = new Map<string, string>(); const controls: any[] = []; const results: any[] = []; const receipts: FailureReceipt[] = []; const launches: Array<{ ticket: ViewTicket; binding: ViewBinding; connectionId?: string; rendered: boolean }> = [];
  const fakeRpc = { status: async () => before, control: async (...args: any[]) => { controls.push(args); return { message: "isolated steer acknowledged", data: {} }; } } as any;
  let actor = createRootActor({ sessionId: input.ownerPiSessionId, generation, rpc: fakeRpc, onProjection: () => {}, onControlResult: (result) => { results.push(result); const connectionId = results.at(-1)?.connectionId ?? controlConnection; if (connectionId) ipc.send(connectionId, { type: "result", requestId: result.requestId, ok: result.ok, message: result.message }); } });
  let controlConnection: string | undefined;
  const ipc = new RendererIpcServer(store.generationRoot, generation, (event) => {
    actor.send(event);
    if (event.type === "RENDER.CONNECTED") { connections.set(event.bindingId, event.connectionId); ipc.publish(event.bindingId, scoped, { supervisors: { smoke: "healthy" } }); if (event.bindingId === "control") controlConnection = event.connectionId; }
    if (event.type === "RENDER.INPUT" && event.intent.kind === "steer") actor.send({ type: "CONTROL.REQUEST", requestId: randomUUID(), identity: { runId: run.id }, operation: "steer", text: event.intent.text });
  });
  actor.start(); await until(() => actor.getSnapshot().matches("ready"), "smoke fake authority did not become ready");
  const home = input.home ?? os.homedir(); const launcher = path.join(home, ".local", "bin", "workstation-tmux-subagents"); const controller = new TmuxController(socket);
  await tmux(socket, ["-f", "/dev/null", "new-session", "-d", "-s", "tmux-subagents-smoke", "sleep 30"]);
  const foreignPaneId = (await tmux(socket, ["display-message", "-p", "-t", "tmux-subagents-smoke:0.0", "#{pane_id}"])).trim();
  const foreignBefore = await controller.inspectPane(foreignPaneId);
  let ipcReadyResolve!: () => void; const ipcReady = new Promise<void>((resolve) => { ipcReadyResolve = resolve; });
  const production = createProductionSupervisorActor({ intervalMs: 25, topologyTimeoutMs: 2_000, startIpc: async () => { await ipc.start(); ipcReadyResolve(); }, stopIpc: () => ipc.stop(), reconcile: async () => {}, publishProjection: async () => {}, receipt: (receipt) => receipts.push(receipt) });
  production.start(); await ipcReady;
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
  const delivery = production.addRenderer({ childId: "renderer:smoke-created", restart: "permanent", run: rendererLogic });
  if (!delivery.delivered) throw new Error(delivery.reason);
  try {
    await until(() => launches.length === 1 && launches[0].rendered, "supervised renderer did not start");
    process.kill(launches[0].binding.pane.panePid, "SIGKILL");
    await until(() => receipts.some((receipt) => receipt.childId === "renderer:smoke-created" && receipt.decision === "restart" && receipt.abnormal === true), "production supervisor did not observe real renderer process failure");
    await until(() => launches.length === 2 && launches[1].rendered, "supervisor did not restart the real renderer process");

    const controlTicket = await store.createTicket({ ticketId: "control", runId: run.id, created: false, rendererSocketPath: ipc.socketPath, nodePath: input.attestation.nodePath, rendererPath: input.attestation.rendererPath, ttlMs: 30_000 }); ipc.register({ ticketId: "control", generation, nonce: controlTicket.nonce, bindingId: "control" });
    const client = ipcClient(ipc.socketPath); await new Promise((resolve) => client.socket.once("connect", resolve)); client.socket.write(`${JSON.stringify({ version: 1, sequence: 1, type: "authenticate", ticketId: "control", generation, nonce: controlTicket.nonce })}\n`); await until(() => client.frames.some((frame) => frame.type === "authenticated"), "control renderer did not authenticate"); client.socket.write(`${JSON.stringify({ version: 1, sequence: 2, type: "intent", intent: { kind: "steer", text: "smoke steer" } })}\n`); await until(() => client.frames.some((frame) => frame.type === "result" && frame.ok), "steer was not acknowledged through the production actor control path"); assertControl(); client.socket.destroy();

    const stale = ipcClient(ipc.socketPath); await new Promise((resolve) => stale.socket.once("connect", resolve)); stale.socket.write(`${JSON.stringify({ version: 1, sequence: 1, type: "authenticate", ticketId: "control", generation: `${generation}-stale`, nonce: controlTicket.nonce })}\n`); await until(() => stale.frames.some((frame) => frame.type === "fatal"), "stale generation authentication was accepted"); stale.socket.destroy();
    production.removeRenderer("renderer:smoke-created"); await detachCreatedThroughTopology(production, controller, launches[1].binding); ipc.revoke(launches[1].ticket.ticketId);
    await until(async () => { try { await controller.inspectPane(launches[1].binding.pane.paneId); return false; } catch { return true; } }, "created renderer pane still exists after detach");
    const foreignAfter = await controller.inspectPane(foreignPaneId); if (JSON.stringify(foreignAfter) !== JSON.stringify(foreignBefore)) throw new Error("smoke changed the foreign seed pane identity tuple");
    const after = await input.rpc.status(); if (JSON.stringify(states(before.runs)) !== JSON.stringify(states(after.runs))) throw new Error("smoke changed authoritative managed-run identity or lifecycle state");
    return `smoke passed: authenticated steer acknowledged, Terminal Kit rendered, real renderer kill restarted by production supervisor, stale generation rejected, created pane absent, foreign pane identity unchanged, authority unchanged`;
  } finally {
    production.stop(); actor.send({ type: "SUPERVISOR.STOP" }); actor.stop(); await ipc.stop().catch(() => {}); await execFileAsync("tmux", ["-S", socket, "kill-server"], { timeout: 3000 }).catch(() => {}); for (const ticket of tickets.values()) await store.removeTicket(ticket, true).catch(() => {}); await store.removeGeneration().catch(() => {});
  }

  function assertControl() {
    if (controls.length !== 1 || controls[0][0] !== "steer" || controls[0][1]?.runId !== run.id || controls[0][2] !== "smoke steer") throw new Error("isolated authority did not receive the exact acknowledged steer");
  }
}
