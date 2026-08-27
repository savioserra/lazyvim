import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readdir } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { createTmuxSubagentsExtension, type ExtensionConfig } from "../../home/dot_pi/agent/extensions/tmux-subagents/index.ts";
import { ASYNC_SNAPSHOT_KIND, RPC_REPLY_PREFIX, RPC_REQUEST_EVENT } from "../../home/dot_pi/agent/extensions/tmux-subagents/domain/constants.ts";

const config: ExtensionConfig = { schemaVersion: 1, extensionVersion: "0.2.0", enabled: true, compatiblePiSubagentsVersion: "0.56.0", rpcTimeoutMs: 500, ticketTtlMs: 1000, projectionIntervalMs: 250, runtime: { enabled: true, xstateVersion: "5.32.6", terminalKitVersion: "3.1.4", actorProtocolVersion: 1 } };

function harness(overrides: { config?: ExtensionConfig; version?: string; attestError?: Error; smokeError?: Error } = {}) {
	const root = path.join(os.tmpdir(), `te-${randomUUID().slice(0, 8)}`);
	const listeners = new Map<string, Set<(payload: any) => void>>();
	const events = {
		on(name: string, listener: (payload: any) => void) { const set = listeners.get(name) ?? new Set(); set.add(listener); listeners.set(name, set); return () => set.delete(listener); },
		emit(name: string, payload: any) {
			if (name === RPC_REQUEST_EVENT) {
				const data = payload.method === "ping"
					? { version: 1, methods: ["ping", "status", "steer", "interrupt", "stop", "resume"], capabilities: { asyncStatusSnapshot: { kind: ASYNC_SNAPSHOT_KIND, version: 1 } }, events: { asyncComplete: "subagent:async-complete", childStatus: "subagent:child-status", processTerminal: "subagent:process-terminal" }, session: { sessionId: "session-1" } }
					: { asyncSnapshot: { kind: ASYNC_SNAPSHOT_KIND, version: 1, generatedAt: 1, omitted: { runs: 0, children: 0, byteLimitExceeded: false }, runs: [{ id: "run-1", kind: "workflow", label: "worker", state: "running", children: [{ id: "child-1", kind: "step", label: "step", state: "running" }] }] } };
				queueMicrotask(() => events.emit(RPC_REPLY_PREFIX + payload.requestId, { version: 1, requestId: payload.requestId, method: payload.method, success: true, data }));
			}
			for (const listener of listeners.get(name) ?? []) listener(payload);
		},
	};
	const lifecycle = new Map<string, Function>();
	let command: any;
	const pi = { events, on(name: string, handler: Function) { lifecycle.set(name, handler); }, registerCommand(_name: string, definition: any) { command = definition; } } as any;
	const notices: string[] = [];
	const context = { cwd: "/tmp", sessionManager: { getSessionId: () => "session-1" }, ui: { notify: (message: string) => notices.push(message) }, reload: async () => {} } as any;
	createTmuxSubagentsExtension({
		loadConfig: async () => overrides.config ?? config,
		installedPiSubagentsVersion: async () => overrides.version ?? "0.56.0",
		attestRuntime: async () => { if (overrides.attestError) throw overrides.attestError; return { root: "/runtime", rendererPath: "/runtime/renderer.mjs", nodePath: process.execPath, xstateVersion: "5.32.6", terminalKitVersion: "3.1.4" }; },
		runSmoke: async () => { if (overrides.smokeError) throw overrides.smokeError; return "smoke passed: lifecycle complete and managed state unchanged"; },
		privateRoot: () => root,
	})(pi);
	return { lifecycle, get command() { return command; }, context, notices, root };
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

test("smoke fails closed for disabled, missing runtime, incompatible package, and lifecycle failure", async () => {
	for (const options of [
		{ config: { ...config, enabled: false } },
		{ attestError: new Error("runtime tampered") },
		{ version: "0.55.0" },
		{ smokeError: new Error("claim failed") },
	]) {
		const h = harness(options as any); await start(h);
		await assert.rejects(h.command.handler("smoke", h.context), /blocked|tampered|incompatible|claim failed|enable/);
		await stop(h);
	}
});

test("prepare rejects empty, unknown, and mismatched child identities before pane creation", async () => {
	const h = harness(); await start(h);
	await assert.rejects(h.command.handler("prepare missing", h.context), /not visible/);
	await assert.rejects(h.command.handler("prepare run-1 missing", h.context), /does not belong/);
	await assert.rejects(h.command.handler("prepare", h.context), /usage/);
	await stop(h);
});
