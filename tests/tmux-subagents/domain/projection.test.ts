import assert from "node:assert/strict";
import test from "node:test";
import { ASYNC_SNAPSHOT_KIND, MAX_PROJECTION_BYTES } from "../../../home/dot_pi/agent/extensions/tmux-subagents/domain/constants.ts";
import { decodeAsyncSnapshot, renderProjectionText, sanitizeText, scopeProjection } from "../../../home/dot_pi/agent/extensions/tmux-subagents/domain/projection.ts";

function snapshot(runs: unknown[]) {
	return {
		kind: ASYNC_SNAPSHOT_KIND,
		version: 1,
		generatedAt: 1,
		caps: { maxRuns: 20 },
		omitted: { runs: 0, children: 0, byteLimitExceeded: false },
		runs,
	};
}

test("projection strips terminal controls, newlines, and bidi overrides", () => {
	assert.equal(sanitizeText("\u001b[31mred\u001b[0m\nnext\u202e"), "red next");
	const projection = decodeAsyncSnapshot(
		snapshot([{ id: "run\n1", kind: "subagent", label: "\u001b[2Jworker", state: "running", activity: { currentTool: "read\rsecret" } }]),
	);
	const rendered = renderProjectionText(projection);
	assert.match(rendered, /worker · running · read secret/);
	assert.doesNotMatch(rendered, /\u001b|\r/);
});

test("projection is bounded by run, child, depth, and serialized byte caps", () => {
	const child = (depth: number): unknown => ({
		id: `child-${depth}`,
		kind: "step",
		label: "x".repeat(1000),
		state: "running",
		children: depth > 0 ? [child(depth - 1)] : [],
	});
	const crowded = { ...(child(5) as Record<string, unknown>), children: Array.from({ length: 12 }, () => child(5)) };
	const projection = decodeAsyncSnapshot(snapshot(Array.from({ length: 40 }, (_, index) => ({ ...crowded, id: `run-${index}`, kind: "workflow" }))));
	assert.ok(projection.runs.length <= 20);
	assert.ok(projection.omitted.runs >= 20);
	assert.ok(projection.omitted.children > 0);
	assert.ok(Buffer.byteLength(JSON.stringify(projection)) <= MAX_PROJECTION_BYTES);
});

test("projection requires a visible run and scopes an optional child", () => {
	const projection = decodeAsyncSnapshot(snapshot([{ id: "run-1", kind: "workflow", label: "flow", state: "running", children: [{ id: "child-1", kind: "step", label: "step", state: "running" }] }]));
	assert.equal(scopeProjection(projection, "run-1").runs[0]?.id, "run-1");
	assert.equal(scopeProjection(projection, "run-1", "child-1").runs[0]?.children?.[0]?.id, "child-1");
	assert.throws(() => scopeProjection(projection, ""), /run id is required/);
	assert.throws(() => scopeProjection(projection, "missing"), /not visible/);
	assert.throws(() => scopeProjection(projection, "run-1", "missing"), /does not belong/);
});

test("projection rejects unknown state instead of rendering it", () => {
	assert.throws(() => decodeAsyncSnapshot(snapshot([{ id: "run", kind: "subagent", label: "agent", state: "secret-state" }])), /invalid state/);
});
