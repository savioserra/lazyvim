import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { PrivateViewStore } from "../../../home/dot_pi/agent/extensions/tmux-subagents/adapters/store.ts";

const posixOnly = { skip: process.platform === "win32" };

async function storeFixture() {
	const root = await mkdtemp(path.join(os.tmpdir(), "tmux-subagents-store-"));
	const store = new PrivateViewStore(root, "session-1", "generation-1");
	await store.initialize();
	return { root, store };
}

test("ticket and projection records are private and bounded", posixOnly, async () => {
	const { store } = await storeFixture();
	await assert.rejects(
		store.createTicket({ runId: "created-without-pane", created: true, ttlMs: 1000, now: 100 }),
		/require one exact expected pane identity/,
	);
	const expectedPane = { socketPath: "/tmp/tmux", paneId: "%2", panePid: 123, paneTty: "/dev/pts/2", sessionId: "$1" };
	const createdTicket = await store.createTicket({ runId: "run-created", created: true, expectedPane, ttlMs: 1000, now: 100 });
	assert.deepEqual((await store.readTicket(createdTicket.ticketId, 101)).expectedPane, expectedPane);
	const ticket = await store.createTicket({ runId: "run-1", created: false, ttlMs: 1000, now: 100 });
	assert.equal((await stat(store.sessionRoot)).mode & 0o777, 0o700);
	assert.equal((await stat(store.ticketPath(ticket.ticketId))).mode & 0o777, 0o600);
	assert.equal((await stat(ticket.projectionPath)).mode & 0o777, 0o600);
	assert.match(await readFile(ticket.projectionPath, "utf8"), /Waiting/);
});

test("supervisor restart receipts persist only bounded durable counters, not actor refs", posixOnly, async () => {
	const { store } = await storeFixture();
	await store.writeSupervisorReceipt({ supervisorId: "render-supervisor", childId: "renderer-1", decision: "restart", reason: "exited", at: 100, restartAttempt: 2 });
	const files = await (await import("node:fs/promises")).readdir(store.receiptsRoot); assert.equal(files.length, 1);
	const file = path.join(store.receiptsRoot, files[0]); assert.equal((await stat(file)).mode & 0o777, 0o600);
	const value = JSON.parse(await readFile(file, "utf8")); assert.equal(value.restartAttempt, 2); assert.equal(JSON.stringify(value).includes("ref"), false);
});

test("ticket expiry, nonce mismatch, and one-use consumption fail closed", posixOnly, async () => {
	const { store } = await storeFixture();
	const expired = await store.createTicket({ runId: "run-expired", created: false, ttlMs: 1, now: 100 });
	await assert.rejects(store.readTicket(expired.ticketId, 102), /expired/);

	const ticket = await store.createTicket({ runId: "run-1", childId: "step:1", created: false, ttlMs: 1000, now: 100 });
	await writeFile(
		ticket.claimPath,
		JSON.stringify({ schemaVersion: 1, ticketId: ticket.ticketId, nonce: "wrong", tmux: "/tmp/tmux,1,0", paneId: "%2", claimedAt: 101 }),
		{ mode: 0o600 },
	);
	await assert.rejects(store.consumeClaim(ticket.ticketId, 102), /does not match/);
	await writeFile(
		ticket.claimPath,
		JSON.stringify({ schemaVersion: 1, ticketId: ticket.ticketId, nonce: ticket.nonce, tmux: "/tmp/tmux,1,0", paneId: "%2", claimedAt: 101 }),
		{ mode: 0o600 },
	);
	assert.equal((await store.consumeClaim(ticket.ticketId, 102)).claim.paneId, "%2");
	await assert.rejects(store.consumeClaim(ticket.ticketId, 102), /ENOENT|no such file/);
});

test("private storage rejects path escapes, symlink swaps, and unsafe permissions", posixOnly, async () => {
	const { root, store } = await storeFixture();
	await assert.rejects(store.closeProjection(path.join(root, "escape.txt")), /escapes generation root/);
	const ticket = await store.createTicket({ runId: "run-safe", created: false, ttlMs: 1000 });
	await chmod(store.ticketPath(ticket.ticketId), 0o644);
	await assert.rejects(store.readTicket(ticket.ticketId), /mode 600/);
	await chmod(store.ticketPath(ticket.ticketId), 0o600);
	const outside = path.join(root, "outside-ticket");
	await writeFile(outside, "{}\n", { mode: 0o600 });
	await rm(store.ticketPath(ticket.ticketId));
	await symlink(outside, store.ticketPath(ticket.ticketId));
	await assert.rejects(store.readTicket(ticket.ticketId), /symlink/);
	await rm(store.projectionsRoot, { recursive: true });
	await symlink(path.join(root, "outside"), store.projectionsRoot);
	await assert.rejects(store.writeProjection(ticket, { schemaVersion: 1, generatedAt: 1, source: "pi-subagents-rpc", omitted: { runs: 0, children: 0, sourceByteLimitExceeded: false, projectionByteLimitExceeded: false }, runs: [] }), /symlink|owned directory/);
});

test("concurrent claims consume exactly once", posixOnly, async () => {
	const { store } = await storeFixture();
	const ticket = await store.createTicket({ runId: "run-race", created: false, ttlMs: 1000, now: 100 });
	await writeFile(ticket.claimPath, JSON.stringify({ schemaVersion: 1, ticketId: ticket.ticketId, nonce: ticket.nonce, tmux: "/tmp/tmux,1,0", paneId: "%2", claimedAt: 101 }), { mode: 0o600 });
	const results = await Promise.allSettled([store.consumeClaim(ticket.ticketId, 102), store.consumeClaim(ticket.ticketId, 102)]);
	assert.equal(results.filter((result) => result.status === "fulfilled").length, 1);
	assert.equal(results.filter((result) => result.status === "rejected").length, 1);
});

test("expired tickets are enumerated for generation reaping", posixOnly, async () => {
	const { store } = await storeFixture();
	const expired = await store.createTicket({ runId: "run-expired", created: false, ttlMs: 1, now: 100 });
	const active = await store.createTicket({ runId: "run-active", created: false, ttlMs: 1000, now: 100 });
	assert.deepEqual((await store.expiredTickets(102)).map((ticket) => ticket.ticketId), [expired.ticketId]);
	await store.removeTicket(expired, true);
	assert.equal((await store.expiredTickets(102)).some((ticket) => ticket.ticketId === active.ticketId), false);
});

test("a new generation discovers and can reap stale owned generations", posixOnly, async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), "tmux-subagents-generations-"));
	const oldStore = new PrivateViewStore(root, "session-1", "old-generation");
	await oldStore.initialize();
	await oldStore.createTicket({ runId: "run-old", created: false, ttlMs: 1, now: 1 });
	const newStore = new PrivateViewStore(root, "session-1", "new-generation");
	await newStore.initialize();
	const prior = await newStore.priorGenerations();
	assert.deepEqual(prior.map((store) => store.generation), ["old-generation"]);
	await prior[0]?.removeGeneration();
	assert.deepEqual(await newStore.priorGenerations(), []);
});

test("generation ownership prevents a stale extension from persisting bindings", posixOnly, async () => {
	const { store } = await storeFixture();
	await assert.rejects(
		store.writeBinding({
			schemaVersion: 1,
			bindingId: "binding-1",
			generation: "generation-2",
			ownerPiSessionId: "session-1",
			runId: "run-1",
			created: false,
			projectionPath: path.join(store.projectionsRoot, "run.txt"),
			pane: { socketPath: "/tmp/tmux", paneId: "%1", panePid: 1, paneTty: "/dev/pts/1", sessionId: "$1" },
			createdAt: 1,
		}),
		/foreign binding/,
	);
});
