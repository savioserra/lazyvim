import assert from "node:assert/strict";
import test from "node:test";
import { ASYNC_SNAPSHOT_KIND, RPC_REPLY_PREFIX, RPC_REQUEST_EVENT } from "../../../home/dot_pi/agent/extensions/tmux-subagents/domain/constants.ts";
import { decodeCompatiblePing, SubagentsRpcClient, type EventBus } from "../../../home/dot_pi/agent/extensions/tmux-subagents/adapters/pi-subagents-rpc.ts";

class FakeEvents implements EventBus {
	listeners = new Map<string, Set<(payload: unknown) => void | Promise<void>>>();
	on(event: string, listener: (payload: unknown) => void | Promise<void>): () => void {
		const values = this.listeners.get(event) ?? new Set();
		values.add(listener);
		this.listeners.set(event, values);
		return () => values.delete(listener);
	}
	emit(event: string, payload: unknown): void {
		for (const listener of this.listeners.get(event) ?? []) void listener(payload);
	}
}

function pingData() {
	return {
		version: 1,
		methods: ["ping", "status", "steer", "interrupt", "stop", "resume"],
		capabilities: { asyncStatusSnapshot: { kind: ASYNC_SNAPSHOT_KIND, version: 1 } },
		events: {
			asyncComplete: "subagent:async-complete",
			childStatus: "subagent:child-status",
			processTerminal: "subagent:process-terminal",
		},
		session: { sessionId: "session" },
	};
}

test("RPC correlates replies and decodes the exact observer contract", async () => {
	const events = new FakeEvents();
	events.on(RPC_REQUEST_EVENT, (payload) => {
		const request = payload as { requestId: string; method: string };
		events.emit(RPC_REPLY_PREFIX + request.requestId, {
			version: 1,
			requestId: request.requestId,
			method: request.method,
			success: true,
			data:
				request.method === "ping"
					? pingData()
					: {
							asyncSnapshot: {
								kind: ASYNC_SNAPSHOT_KIND,
								version: 1,
								generatedAt: 1,
								caps: {},
								omitted: { runs: 0, children: 0, byteLimitExceeded: false },
								runs: [{ id: "run", kind: "subagent", label: "worker", state: "running" }],
							},
						},
		});
	});
	const client = new SubagentsRpcClient(events, 100);
	assert.equal((await client.ping()).sessionId, "session");
	assert.equal((await client.status()).runs[0]?.label, "worker");
});

test("control RPC maps exact run and child identities to documented methods", async () => {
	const events = new FakeEvents(); const requests: any[] = [];
	events.on(RPC_REQUEST_EVENT, (payload: any) => { requests.push(payload); events.emit(RPC_REPLY_PREFIX + payload.requestId, { version: 1, requestId: payload.requestId, method: payload.method, success: true, data: { text: payload.method === "steer" ? "\u001b[31mack\nnow" : `${payload.method} acknowledged` } }); });
	const client = new SubagentsRpcClient(events, 100);
	assert.equal((await client.control("steer", { runId: "run", childId: "child" }, "focus")).message, "ack now");
	await client.control("interrupt", { runId: "run", childId: "child" });
	await client.control("stop", { runId: "run", childId: "child" });
	await client.control("resume", { runId: "run", childId: "child" }, "continue");
	assert.deepEqual(requests.map(({ method, params }) => ({ method, params })), [
		{ method: "steer", params: { id: "child", message: "focus", mode: "steer" } },
		{ method: "interrupt", params: { id: "child" } },
		{ method: "stop", params: { id: "run", childId: "child" } },
		{ method: "resume", params: { id: "child", message: "continue" } },
	]);
});

test("RPC fails closed on timeout", async () => {
	await assert.rejects(new SubagentsRpcClient(new FakeEvents(), 5).ping(), /timed out/);
});

test("ping rejects incompatible capabilities and events", () => {
	assert.throws(() => decodeCompatiblePing({ ...pingData(), version: 2 }), /unsupported/);
	const changed = pingData();
	changed.events.childStatus = "private:event";
	assert.throws(() => decodeCompatiblePing(changed), /incompatible childStatus/);
});
