import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readdir } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { createTmuxSubagentsExtension, tmuxSubagentsClosedMessage, type ExtensionConfig } from "../../home/dot_pi/private_agent/extensions/tmux-subagents/index.ts";
import { DiagnosticJournal } from "../../home/dot_pi/private_agent/extensions/tmux-subagents/adapters/diagnostic-journal.ts";
import { PrivateViewStore } from "../../home/dot_pi/private_agent/extensions/tmux-subagents/adapters/store.ts";
import { ASYNC_SNAPSHOT_KIND, RPC_REPLY_PREFIX, RPC_REQUEST_EVENT } from "../../home/dot_pi/private_agent/extensions/tmux-subagents/domain/constants.ts";

const config: ExtensionConfig = { schemaVersion: 1, extensionVersion: "0.2.0", enabled: true, compatiblePiSubagentsVersion: "0.56.0", rpcTimeoutMs: 500, ticketTtlMs: 1000, projectionIntervalMs: 250, runtime: { enabled: true, xstateVersion: "5.32.6", terminalKitVersion: "3.1.4", actorProtocolVersion: 1 } };

function harness(overrides: { config?: ExtensionConfig; version?: string; attestError?: Error; smokeError?: Error; ipcStartError?: Error; ipcStopError?: Error; rpcPingError?: Error; smokeHook?: () => Promise<void>; rootConstructorError?: Error; rootStartError?: Error; supervisorConstructorError?: Error; supervisorStartError?: Error; storeInitializeError?: Error; diagnosticConstructorError?: Error; journalCloseError?: Error; generationRemovalError?: Error; leaseReleaseError?: Error } = {}) {
	const root = path.join(os.tmpdir(), `te-${randomUUID().slice(0, 8)}`);
	const listeners = new Map<string, Set<(payload: any) => void>>();
	const events = {
		on(name: string, listener: (payload: any) => void) { const set = listeners.get(name) ?? new Set(); set.add(listener); listeners.set(name, set); return () => set.delete(listener); },
		emit(name: string, payload: any) {
			if (name === RPC_REQUEST_EVENT) {
				const data = payload.method === "ping"
					? { version: 1, methods: ["ping", "status", "steer", "interrupt", "stop", "resume"], capabilities: { asyncStatusSnapshot: { kind: ASYNC_SNAPSHOT_KIND, version: 1 } }, events: { asyncComplete: "subagent:async-complete", childStatus: "subagent:child-status", processTerminal: "subagent:process-terminal" }, session: { sessionId: "session-1" } }
					: { asyncSnapshot: { kind: ASYNC_SNAPSHOT_KIND, version: 1, generatedAt: 1, omitted: { runs: 0, children: 0, byteLimitExceeded: false }, runs: [{ id: "run-1", kind: "workflow", label: "worker", state: "running", children: [{ id: "child-1", kind: "step", label: "step", state: "running" }] }] } };
				queueMicrotask(() => events.emit(RPC_REPLY_PREFIX + payload.requestId, overrides.rpcPingError && payload.method === "ping" ? { version: 1, requestId: payload.requestId, method: payload.method, success: false, error: { code: "ping_failed", message: overrides.rpcPingError.message } } : { version: 1, requestId: payload.requestId, method: payload.method, success: true, data }));
			}
			for (const listener of listeners.get(name) ?? []) listener(payload);
		},
	};
	const lifecycle = new Map<string, Function>();
	let command: any;
	const pi = { events, on(name: string, handler: Function) { lifecycle.set(name, handler); }, registerCommand(_name: string, definition: any) { command = definition; } } as any;
	const notices: string[] = []; const ipc = { starts: 0, stops: 0 }; const cleanup = { supervisorStops: 0, generationRemovals: 0, leaseReleases: 0, journalCloses: 0 };
	const context = { cwd: "/tmp", sessionManager: { getSessionId: () => "session-1" }, ui: { notify: (message: string) => notices.push(message) }, reload: async () => {} } as any;
	createTmuxSubagentsExtension({
		loadConfig: async () => overrides.config ?? config,
		installedPiSubagentsVersion: async () => overrides.version ?? "0.56.0",
		attestRuntime: async () => { if (overrides.attestError) throw overrides.attestError; return { root: "/runtime", rendererPath: "/runtime/renderer.mjs", nodePath: process.execPath, xstateVersion: "5.32.6", terminalKitVersion: "3.1.4" }; },
		runSmoke: async () => { await overrides.smokeHook?.(); if (overrides.smokeError) throw overrides.smokeError; return "smoke passed: lifecycle complete and managed state unchanged"; },
		privateRoot: () => root,
		...((overrides.ipcStartError || overrides.ipcStopError) ? { createIpcServer: (...args: any[]) => ({ socketPath: path.join(args[0], "sockets/renderer.sock"), start: async () => { ipc.starts += 1; if (overrides.ipcStartError) throw overrides.ipcStartError; }, stop: async () => { ipc.stops += 1; if (overrides.ipcStopError) throw overrides.ipcStopError; }, publish() {}, register() {}, revoke() {}, bindingFor() {}, send() {} }) as any } : {}),
		...((overrides.rootConstructorError || overrides.rootStartError) ? { createRootActor: (() => { if (overrides.rootConstructorError) throw overrides.rootConstructorError; return { id: "fault-root", start() { throw overrides.rootStartError; }, stop() {}, send() {}, getSnapshot() { return { value: "starting", context: { supervisorHealth: {} } }; } }; }) as any } : {}),
		...((overrides.supervisorConstructorError || overrides.supervisorStartError) ? { createProductionSupervisor: (() => { if (overrides.supervisorConstructorError) throw overrides.supervisorConstructorError; return { start() { throw overrides.supervisorStartError; }, async stop() { cleanup.supervisorStops += 1; } }; }) as any } : {}),
		...((overrides.journalCloseError || overrides.diagnosticConstructorError) ? { createDiagnosticJournal: ((generationRoot: string, generation: string) => { if (overrides.diagnosticConstructorError) throw overrides.diagnosticConstructorError; const journal = new DiagnosticJournal(generationRoot, generation); journal.close = async () => { cleanup.journalCloses += 1; throw overrides.journalCloseError; }; return journal; }) as any } : {}),
		...((overrides.storeInitializeError || overrides.generationRemovalError || overrides.leaseReleaseError) ? { createStore: ((storeRoot: string, session: string, generation: string) => { const store = new PrivateViewStore(storeRoot, session, generation); const initialize = store.initialize.bind(store); const remove = store.removeOwnedGeneration.bind(store); const release = store.releaseLease.bind(store); store.initialize = async () => { await initialize(); if (overrides.storeInitializeError) throw overrides.storeInitializeError; }; store.removeOwnedGeneration = async () => { cleanup.generationRemovals += 1; if (overrides.generationRemovalError && cleanup.generationRemovals === 1) throw overrides.generationRemovalError; await remove(); }; store.releaseLease = async () => { cleanup.leaseReleases += 1; if (overrides.leaseReleaseError && cleanup.leaseReleases === 1) throw overrides.leaseReleaseError; await release(); }; return store; }) as any } : {}),
	})(pi);
	return { lifecycle, get command() { return command; }, context, notices, root, ipc, cleanup };
}

async function start(h: ReturnType<typeof harness>) { await h.lifecycle.get("session_start")?.({}, h.context); }
async function stop(h: ReturnType<typeof harness>) { await h.lifecycle.get("session_shutdown")?.({}, h.context); }

test("extension lifecycle initializes once and smoke succeeds only through attested state", async () => {
	const h = harness(); await start(h);
	await h.command.handler("smoke", h.context);
	assert.match(h.notices.at(-1) ?? "", /smoke passed/);
	await stop(h);
	const sessions = await readdir(h.root).catch(() => [] as string[]);
	if (sessions.length > 0) {
		const generations = await readdir(path.join(h.root, sessions[0], "generations"));
		assert.deepEqual(generations, [], "session shutdown must reap its generation");
	}
});

test("RPC ping failure transactionally removes the incomplete production generation", async () => {
	const h = harness({ rpcPingError: new Error("ping unavailable") }); await start(h); assert.equal(h.ipc.starts, 0); const sessions = await readdir(h.root); const generations = await readdir(path.join(h.root, sessions[0], "generations")); assert.deepEqual(generations.length, 1); assert.match(generations[0], /^bootstrap-/); await stop(h);
});

test("IPC startup failure rolls back the production supervisor before bootstrap diagnostics starts", async () => {
	const h = harness({ ipcStartError: new Error("IPC bind failed") }); await start(h); assert.equal(h.ipc.starts, 1); assert.ok(h.ipc.stops >= 1); await new Promise((resolve) => setTimeout(resolve, 350)); assert.equal(h.ipc.starts, 1, "rolled-back production supervisor retried IPC startup");
	const sessions = await readdir(h.root); const generations = await readdir(path.join(h.root, sessions[0], "generations")); assert.equal(generations.length, 1, "failed production generation was orphaned alongside bootstrap diagnostics"); assert.match(generations[0], /^bootstrap-/); await stop(h);
});

test("store, diagnostics, root/supervisor construction, and root/supervisor start failures run the same complete rollback", async () => {
	for (const options of [{ storeInitializeError: new Error("store initialization failed") }, { diagnosticConstructorError: new Error("diagnostic constructor failed") }, { rootConstructorError: new Error("root constructor failed") }, { rootStartError: new Error("root start failed") }, { supervisorConstructorError: new Error("supervisor constructor failed") }, { supervisorStartError: new Error("supervisor start failed") }]) {
		const h = harness(options); await start(h); const sessions = await readdir(h.root); const generations = await readdir(path.join(h.root, sessions[0], "generations")); assert.equal(generations.length, 1); assert.match(generations[0], /^bootstrap-/); if (options.supervisorStartError) assert.equal(h.cleanup.supervisorStops, 1); await stop(h);
	}
});

test("journal close and IPC stop failures are awaited, reported, and do not block owned generation removal", async () => {
	for (const options of [{ journalCloseError: new Error("journal close failed") }, { ipcStopError: new Error("IPC stop failed") }]) {
		const h = harness(options); await start(h); await assert.rejects(stop(h), /cleanup was incomplete/); const sessions = await readdir(h.root); const generations = await readdir(path.join(h.root, sessions[0], "generations")); assert.deepEqual(generations, []); if (options.journalCloseError) assert.equal(h.cleanup.journalCloses, 1); if (options.ipcStopError) assert.ok(h.ipc.stops >= 1);
	}
});

test("generation removal falls back to owned lease release and aggregates release failure", async () => {
	const released = harness({ generationRemovalError: new Error("generation removal failed") }); await start(released); await assert.rejects(stop(released), /cleanup was incomplete/); assert.equal(released.cleanup.generationRemovals, 1); assert.equal(released.cleanup.leaseReleases, 1); await stop(released); assert.equal(released.cleanup.generationRemovals, 2, "disposed state blocked generation-removal retry");
	const failed = harness({ generationRemovalError: new Error("generation removal failed"), leaseReleaseError: new Error("lease release failed") }); await start(failed); await assert.rejects(stop(failed), (error: AggregateError) => error.errors.some((item) => String(item).includes("generation removal failed")) && error.errors.some((item) => String(item).includes("lease release failed"))); assert.equal(failed.cleanup.generationRemovals, 1); assert.equal(failed.cleanup.leaseReleases, 1);
});

test("smoke fails closed for disabled, missing runtime, incompatible package, and lifecycle failure", async () => {
	for (const options of [
		{ config: { ...config, enabled: false } },
		{ attestError: new Error("runtime tampered") },
		{ version: "0.55.0" },
		{ smokeError: new Error("claim failed") },
	]) {
		const h = harness(options as any); await start(h);
		await assert.rejects(h.command.handler("smoke", h.context), /receipt|no durable receipt/);
		await stop(h);
	}
});

test("disabled commands still receive a durable bootstrap failure receipt", async () => {
	const h = harness({ config: { ...config, enabled: false } }); await start(h); let receipt = "";
	await assert.rejects(h.command.handler("smoke", h.context), (error: Error) => { receipt = /\[receipt ([^\]]+)\]/.exec(error.message)?.[1] ?? ""; return receipt.startsWith("command:"); });
	await h.command.handler("diagnostics 20", h.context); assert.match(h.notices.at(-1) ?? "", new RegExp(receipt)); await stop(h);
});

test("bootstrap diagnostics persist initialization failures before the full actor system is ready", async () => {
	const h = harness({ attestError: new Error("runtime credential=/private/value was rejected") }); await start(h);
	await h.command.handler("diagnostics 20", h.context);
	assert.match(h.notices.at(-1) ?? "", /system-initialize failure/);
	assert.match(h.notices.at(-1) ?? "", /authentication or credential validation failed/);
	assert.doesNotMatch(h.notices.at(-1) ?? "", /credential=|\/private\/value/);
	await stop(h);
});

test("command rejects explicitly when durable success completion cannot be appended", async () => {
	let journalPath = ""; const h = harness({ smokeHook: async () => { await (await import("node:fs/promises")).chmod(journalPath, 0o666); } }); await start(h); const sessions = await readdir(h.root); const generations = await readdir(path.join(h.root, sessions[0], "generations")); journalPath = path.join(h.root, sessions[0], "generations", generations[0], "diagnostics", "events.ndjson");
	await assert.rejects(h.command.handler("smoke", h.context), /completed but durable success persistence failed/); await (await import("node:fs/promises")).chmod(journalPath, 0o600); await new Promise((resolve) => setTimeout(resolve, 180)); await stop(h);
});

test("command failure is durably journaled and its receipt is retrievable through diagnostics", async () => {
	const h = harness({ smokeError: new Error("authority snapshot unavailable") }); await start(h);
	let receipt = "";
	await assert.rejects(h.command.handler("smoke", h.context), (error: Error) => { receipt = /\[receipt ([^\]]+)\]/.exec(error.message)?.[1] ?? ""; return receipt.startsWith("command:"); });
	await h.command.handler("diagnostics 50", h.context);
	assert.match(h.notices.at(-1) ?? "", new RegExp(`latest error ${receipt}`));
	assert.match(h.notices.at(-1) ?? "", /required local capability was unavailable/);
	await stop(h);
});

test("close notification is descriptive and does not echo caller supplied raw binding IDs", () => {
	const message = tmuxSubagentsClosedMessage();
	assert.equal(message, "closed tmux-subagents view; managed run unchanged");
	assert.doesNotMatch(message, /run-raw|binding|%\d|pane|socket|pid|handle|fence/i);
});

test("prepare rejects empty, unknown, and mismatched child identities before pane creation", async () => {
	const h = harness(); await start(h);
	await assert.rejects(h.command.handler("prepare missing", h.context), /receipt/);
	await assert.rejects(h.command.handler("prepare run-1 missing", h.context), /receipt/);
	await assert.rejects(h.command.handler("prepare", h.context), /receipt/);
	await stop(h);
});
