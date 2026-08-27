import assert from "node:assert/strict";
import test from "node:test";
import { createAgentMirrorActor, createRootActor } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/actors/root.ts";
import type { Projection } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/domain/projection.ts";

const projection: Projection = {
	schemaVersion: 1, generatedAt: 1, source: "pi-subagents-rpc",
	omitted: { runs: 0, children: 0, sourceByteLimitExceeded: false, projectionByteLimitExceeded: false },
	runs: [{ id: "run", kind: "workflow", label: "workflow", state: "running", children: [{ id: "child", kind: "step", label: "worker", state: "running" }] }],
};
async function until(predicate: () => boolean) { for (let attempt = 0; attempt < 100; attempt++) { if (predicate()) return; await new Promise((resolve) => setTimeout(resolve, 5)); } throw new Error("timed out"); }

test("root XState actor boots OTP boundaries and treats event hints only as authoritative refresh triggers", async () => {
	let statuses = 0; const published: Projection[] = [];
	const rpc = { status: async () => { statuses += 1; return projection; }, control: async () => ({ message: "ack", data: {} }) } as any;
	const root = createRootActor({ sessionId: "session", generation: "generation", rpc, onProjection: (value) => published.push(value) });
	root.start(); await until(() => root.getSnapshot().matches("ready"));
	assert.ok(root.system.get("run-mirror-supervisor"), "authoritative snapshots must own their mirror boundary");
	for (const removed of ["integration-supervisor", "tmux-supervisor", "render-supervisor", "projection-supervisor-boundary"]) assert.equal(root.system.get(removed), undefined, `${removed} decorative proxy must not exist`);
	assert.equal(statuses, 1); assert.equal(published.length, 1);
	root.send({ type: "AUTHORITY.HINT", source: "event-bus" });
	await until(() => statuses === 2 && root.getSnapshot().matches("ready"));
	assert.equal(published.at(-1), projection);
	root.send({ type: "SUPERVISOR.STOP" }); root.stop();
});

test("one mirror actor snapshot is local observation and cannot mutate authoritative run state", () => {
	const node = projection.runs[0];
	const mirror = createAgentMirrorActor({ identity: { runId: "run" }, node });
	mirror.start();
	mirror.send({ type: "AUTHORITY.SNAPSHOT", snapshot: { ...node, state: "complete" } });
	assert.equal(mirror.getSnapshot().context.node.state, "complete");
	assert.equal(projection.runs[0].state, "running", "mirror updates must not mutate the authoritative projection");
	mirror.send({ type: "RUN.REMOVED", identity: { runId: "run" } });
	assert.equal(mirror.getSnapshot().status, "done");
});

test("local boundary escalation disables controls and never mutates authority", async () => {
	let controls = 0; const results: any[] = [];
	const rpc = { status: async () => projection, control: async () => { controls += 1; return { message: "unexpected", data: {} }; } } as any;
	const root = createRootActor({ sessionId: "session", generation: "local-failure", rpc, onProjection: () => {}, onControlResult: (event) => results.push(event) });
	root.start(); await until(() => root.getSnapshot().matches("ready")); root.send({ type: "CHILD.FAILED", childId: "renderer-ipc", reason: "socket failed", abnormal: true, at: 1 });
	await until(() => root.getSnapshot().matches("degraded")); root.send({ type: "CONTROL.REQUEST", requestId: "request", identity: { runId: "run" }, operation: "stop", confirmed: true });
	await until(() => results.length === 1); assert.equal(controls, 0); assert.equal(projection.runs[0].state, "running"); root.send({ type: "SUPERVISOR.STOP" }); root.stop();
});

test("control requests are acknowledged only through pi-subagents RPC using exact identity", async () => {
	const calls: any[] = []; const results: any[] = [];
	const rpc = { status: async () => projection, control: async (...args: any[]) => { calls.push(args); return { message: "stop acknowledged", data: {} }; } } as any;
	const root = createRootActor({ sessionId: "session", generation: "control-generation", rpc, onProjection: () => {}, onControlResult: (event) => results.push(event) });
	root.start(); await until(() => root.getSnapshot().matches("ready"));
	root.send({ type: "CONTROL.REQUEST", requestId: "request", identity: { runId: "run", childId: "child" }, operation: "stop", confirmed: true });
	await until(() => results.length === 1);
	assert.deepEqual(calls, [["stop", { runId: "run", childId: "child" }, undefined]]);
	assert.deepEqual(results[0], { type: "CONTROL.RESULT", requestId: "request", ok: true, message: "stop acknowledged" });
	root.send({ type: "SUPERVISOR.STOP" }); root.stop();
});
