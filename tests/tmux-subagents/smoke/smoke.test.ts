import assert from "node:assert/strict";
import { chmod, cp, mkdir, mkdtemp, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { cleanupSmokeResources, detachCreatedThroughTopology, runSmoke } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/smoke/index.ts";
import { createProductionSupervisorActor } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/actors/supervisors/production.ts";
import type { ViewBinding } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/adapters/store.ts";

const attestation = { root: "/runtime", rendererPath: "/runtime/renderer.mjs", nodePath: process.execPath, xstateVersion: "5.32.6", terminalKitVersion: "3.1.4" };

test("real smoke lifecycle journals its exact authority precondition phase when no run is visible", async () => {
	const events: Array<{ phase: string; status: string }> = [];
	await assert.rejects(runSmoke({ rpc: { status: async () => ({ schemaVersion: 1, generatedAt: 1, source: "pi-subagents-rpc", omitted: { runs: 0, children: 0, sourceByteLimitExceeded: false, projectionByteLimitExceeded: false }, runs: [] }) }, attestation, ownerPiSessionId: "session", generation: "generation", observe: async (event) => { events.push(event); } }), /smoke phase authority-snapshot-precondition failed: smoke requires one visible current-session run/);
	assert.equal(events.at(-1)?.phase, "authority-snapshot-precondition");
	assert.equal(events.at(-1)?.status, "failure");
});

test("smoke establishes cleanup before projection setup and persists the setup failure", async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), "tmux-smoke-early-")); const events: Array<{ phase: string; status: string }> = []; const snapshot = { schemaVersion: 1 as const, generatedAt: 1, source: "pi-subagents-rpc" as const, omitted: { runs: 0, children: 0, sourceByteLimitExceeded: false, projectionByteLimitExceeded: false }, runs: [{ id: "run", kind: "subagent" as const, label: "worker", state: "complete" as const }] };
	await assert.rejects(runSmoke({ rpc: { status: async () => snapshot }, attestation, ownerPiSessionId: "session", generation: "generation", observe: async (event) => { events.push(event); }, operations: { temporaryRoot: async () => root, project: () => { throw new Error("projection setup failed"); } } }), /projection setup failed/);
	await assert.rejects(stat(root), /ENOENT/); assert.ok(events.some((event) => event.phase === "cleanup" && event.status === "success")); assert.equal(events.at(-1)?.status, "failure");
});

test("smoke cleanup awaits every fault and never emits success after cleanup or persistence failure", async () => {
	const calls: string[] = []; const ticket = {} as any;
	const resources = { root: "/unused", socket: "/unused/socket", tmuxStarted: true, actorStarted: true, tickets: new Map([["ticket", ticket]]), production: { stop: async () => { calls.push("production"); throw new Error("production stop failed"); } }, actor: { send: () => { calls.push("actor-send"); throw new Error("actor stop failed"); }, stop: () => { calls.push("actor-stop"); } }, ipc: { stop: async () => { calls.push("ipc-stop"); throw new Error("IPC stop failed"); } }, stopTmux: async () => { calls.push("tmux-stop"); throw new Error("tmux stop failed"); }, store: { removeTicket: async () => { calls.push("unlink"); throw new Error("unlink failed"); }, removeOwnedGeneration: async () => { calls.push("generation-remove"); throw new Error("generation removal failed"); } } };
	await assert.rejects(cleanupSmokeResources(resources, async (event) => { calls.push(`observe-${event.status}`); if (event.status !== "success") throw new Error(`diagnostic ${event.status} persistence failed`); }), (error: AggregateError) => error.errors.length >= 7);
	for (const call of ["production", "actor-send", "ipc-stop", "tmux-stop", "unlink", "generation-remove", "observe-failure"]) assert.ok(calls.includes(call), `cleanup skipped ${call}`); assert.equal(calls.includes("observe-success"), false);
});

test("real smoke runs an isolated Terminal Kit claim/render lifecycle without changing authority", { skip: process.platform === "win32" }, async () => {
	const home = await mkdtemp(path.join(os.tmpdir(), "tmux-smoke-home-"));
	const source = path.resolve("home/dot_pi/private_agent/extensions/tmux-subagents"); const extension = path.join(home, ".pi/agent/extensions/tmux-subagents");
	await mkdir(path.join(home, ".local/bin"), { recursive: true }); await mkdir(path.join(extension, "renderer"), { recursive: true });
	await cp(path.resolve("home/dot_local/bin/executable_workstation-tmux-subagents"), path.join(home, ".local/bin/workstation-tmux-subagents"));
	await cp(path.join(source, "renderer/executable_main.mjs"), path.join(extension, "renderer/main.mjs"));
	for (const file of ["renderer/transport.mjs", "renderer/ui.mjs", "package.json", "package-lock.json"]) await cp(path.join(source, file), path.join(extension, file));
	await cp(path.join(source, "node_modules"), path.join(extension, "node_modules"), { recursive: true });
	await chmod(path.join(home, ".local/bin/workstation-tmux-subagents"), 0o700); await chmod(path.join(extension, "renderer/main.mjs"), 0o700);
	for (const file of ["renderer/transport.mjs", "renderer/ui.mjs", "package.json", "package-lock.json"]) await chmod(path.join(extension, file), 0o600);
	const stable = { schemaVersion: 1 as const, generatedAt: 1, source: "pi-subagents-rpc" as const, omitted: { runs: 0, children: 0, sourceByteLimitExceeded: false, projectionByteLimitExceeded: false }, runs: [{ id: "run", kind: "subagent" as const, label: "smoke-worker", state: "complete" as const }] };
	const phases = new Set<string>(); let calls = 0; const result = await runSmoke({ rpc: { status: async () => { calls += 1; return stable; } }, attestation: { root: extension, rendererPath: path.join(extension, "renderer/main.mjs"), nodePath: process.execPath, xstateVersion: "5.32.6", terminalKitVersion: "3.1.4" }, ownerPiSessionId: "session", generation: "generation", home, observe: async (event) => { if (event.status === "success") phases.add(event.phase); } });
	assert.match(result, /authenticated steer acknowledged.*Terminal Kit rendered.*real renderer kill restarted by production supervisor.*stale generation rejected.*created pane absent.*foreign pane identity unchanged.*authority unchanged/); assert.equal(calls, 2);
	for (const phase of ["authority-snapshot-precondition", "isolated-root", "isolated-tmux", "foreign-tuple-capture", "ipc-start", "renderer-launch-claim-auth-render", "renderer-sigkill-observed", "renderer-supervised-restart", "control-acknowledgement", "stale-generation-rejection", "detach", "created-pane-absent", "foreign-tuple-unchanged", "authority-unchanged", "cleanup"]) assert.ok(phases.has(phase), `missing smoke phase ${phase}`);
	await assert.rejects(runSmoke({ rpc: { status: async () => stable }, attestation: { root: extension, rendererPath: path.join(extension, "renderer/main.mjs"), nodePath: process.execPath, xstateVersion: "5.32.6", terminalKitVersion: "3.1.4" }, ownerPiSessionId: "session", generation: "generation", home, observe: async (event) => { if (event.phase === "detach" && event.status === "success") throw new Error("detach persistence failed"); } }), /smoke phase detach failed: detach persistence failed/);
});

test("smoke detach fails closed while the production topology boundary is unavailable", async () => {
	const binding = {} as ViewBinding;
	for (const reason of ["topology child backoff", "topology child circuit-open"]) {
		let closeCalled = false;
		const production = {
			executeTopology<T>(_operation: () => Promise<T>): Promise<T> {
				return Promise.reject(new Error(reason));
			},
		};
		const controller = { closeCreated: async () => { closeCalled = true; } };
		await assert.rejects(detachCreatedThroughTopology(production, controller, binding), new RegExp(reason));
		assert.equal(closeCalled, false, `detach bypassed production topology while ${reason}`);
	}
});

test("smoke detach does not execute while the production topology supervisor is stopped", async () => {
	const production = createProductionSupervisorActor({
		intervalMs: 10_000,
		startIpc: async () => {},
		stopIpc: async () => {},
		reconcile: async () => {},
		publishProjection: async () => {},
	});
	let closeCalled = false;
	const controller = { closeCreated: async () => { closeCalled = true; } };
	await assert.rejects(detachCreatedThroughTopology(production, controller, {} as ViewBinding), /stopped/);
	assert.equal(closeCalled, false, "detach executed while the production topology supervisor was stopped");
});

test("real smoke lifecycle rejects an attestation that escapes its package", async () => {
	await assert.rejects(runSmoke({ rpc: { status: async () => { throw new Error("must not query RPC"); } }, attestation: { ...attestation, rendererPath: "/other/renderer.mjs" }, ownerPiSessionId: "session", generation: "generation" }), /escaped its package root/);
});
