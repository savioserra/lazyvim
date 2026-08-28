import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { darwinProcessStartIdentity, PrivateViewStore } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/adapters/store.ts";

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

test("supervisor receipts validate decisions and sanitize every persisted field independently", posixOnly, async () => {
	const { store } = await storeFixture(); const secret = "Bearer SAME-SUPERVISOR-SECRET";
	await assert.rejects(store.writeSupervisorReceipt({ supervisorId: "safe", childId: "safe", decision: "evil", reason: "safe", at: 1, restartAttempt: 0 }), /invalid supervisor receipt decision/);
	for (const receipt of [
		{ supervisorId: secret, childId: "safe-child", decision: "restart", reason: "exited", at: 100, restartAttempt: 1 },
		{ supervisorId: "safe-supervisor", childId: secret, decision: "restart", reason: "exited", at: 101, restartAttempt: 2 },
		{ supervisorId: "safe-supervisor-reason", childId: "safe-child-reason", decision: "restart", reason: `prompt output credential=${secret}`, at: 102, restartAttempt: 3 },
		{ supervisorId: "same-domain-input", childId: "same-domain-input", decision: "restart", reason: "exited", at: 103, restartAttempt: 4 },
	]) await store.writeSupervisorReceipt(receipt);
	for (const invalid of [{ supervisorId: 1 }, { childId: 1 }, { reason: 1 }, { at: "1" }, { restartAttempt: "1" }]) await assert.rejects(store.writeSupervisorReceipt({ supervisorId: "safe", childId: "safe", decision: "restart", reason: "safe", at: 1, restartAttempt: 0, ...invalid } as any), /invalid supervisor receipt/);
	const files = await (await import("node:fs/promises")).readdir(store.receiptsRoot); assert.equal(files.length, 4);
	for (const name of files) {
		const file = path.join(store.receiptsRoot, name); assert.equal((await stat(file)).mode & 0o777, 0o600); const value = JSON.parse(await readFile(file, "utf8"));
		assert.match(value.supervisorId, /^supervisor:[a-f0-9]{24}$/); assert.match(value.childId, /^child:[a-f0-9]{24}$/); assert.ok(["CHILD_FAILURE", "AUTHENTICATION"].includes(value.reasonCode)); assert.equal(value.decision, "restart"); assert.doesNotMatch(JSON.stringify(value), /SAME-SUPERVISOR-SECRET|Bearer|prompt|output|credential=/);
		if (value.restartAttempt === 4) assert.notEqual(value.supervisorId.slice(11), value.childId.slice(6), "receipt identifier domains were not separated");
	}
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

test("ticket cleanup suppresses only ENOENT from unlink and readdir", posixOnly, async () => {
	const first = await storeFixture(); const unlinkTicket = await first.store.createTicket({ runId: "run-unlink", created: false, ttlMs: 1000 }); await rm(unlinkTicket.projectionPath); await mkdir(unlinkTicket.projectionPath, { mode: 0o700 }); await assert.rejects(first.store.removeTicket(unlinkTicket, true), /EISDIR|directory/);
	const second = await storeFixture(); const readdirTicket = await second.store.createTicket({ runId: "run-readdir", created: false, ttlMs: 1000 }); await rm(second.store.ticketPath(readdirTicket.ticketId)); await chmod(second.store.ticketsRoot, 0o300); try { await assert.rejects(second.store.removeTicket(readdirTicket), /EACCES|permission/); } finally { await chmod(second.store.ticketsRoot, 0o700); }
});

test("a new generation discovers and can reap stale owned generations", posixOnly, async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), "tmux-subagents-generations-"));
	const oldStore = new PrivateViewStore(root, "session-1", "old-generation");
	await oldStore.initialize();
	await oldStore.createTicket({ runId: "run-old", created: false, ttlMs: 1, now: 1 });
	const newStore = new PrivateViewStore(root, "session-1", "new-generation");
	await newStore.initialize();
	const prior = await newStore.priorGenerations();
	assert.deepEqual(prior.map((store) => store.generation), ["old-generation"]); await oldStore.releaseLease(); const lease = await prior[0]!.reapLease(); assert.equal(lease.status, "stale"); if (lease.status !== "stale") throw new Error("expected stale lease");
	await prior[0]!.removeStaleGeneration(lease.ownerToken, lease.processStartIdentity);
	assert.deepEqual(await newStore.priorGenerations(), []);
});

test("darwin process start identity is stable and usable as non-Linux lease proof", async () => {
	assert.equal(darwinProcessStartIdentity(" Mon Jan  1 00:00:00 2024 \n"), "darwin:Mon Jan  1 00:00:00 2024"); assert.equal(darwinProcessStartIdentity(""), undefined);
	const root = await mkdtemp(path.join(os.tmpdir(), "tmux-subagents-darwin-")); const store = new PrivateViewStore(root, "session-1", "generation-1", { processIdentity: async () => ({ status: "known", identity: "darwin:Mon Jan  1 00:00:00 2024" }) }); await store.initialize();
	assert.match(await readFile(store.leasePath, "utf8"), /darwin:Mon Jan  1 00:00:00 2024/); assert.equal((await store.reapLease()).status, "active"); await store.removeOwnedGeneration();
});

test("owned lease release succeeds and token replacement is detected", posixOnly, async () => {
	const first = await storeFixture(); await first.store.releaseLease(); assert.equal(JSON.parse(await readFile(first.store.leasePath, "utf8")).released, true);
	let raced!: PrivateViewStore; const root = await mkdtemp(path.join(os.tmpdir(), "tmux-subagents-release-race-")); raced = new PrivateViewStore(root, "session-1", "generation-1", { beforeLeaseTransition: async (kind) => { if (kind === "release") await writeFile(raced.leasePath, `${JSON.stringify({ schemaVersion: 1, generation: raced.generation, pid: process.pid, ownerToken: "R".repeat(32), processStartIdentity: "linux:replacement", startedAt: 1 })}\n`, { mode: 0o600 }); } }); await raced.initialize();
	await assert.rejects(raced.releaseLease(), /changed during release/); assert.equal(JSON.parse(await readFile(raced.leasePath, "utf8")).ownerToken, "R".repeat(32));
});

test("owned and stale generation removal detect replacement races without deleting foreign resources", posixOnly, async () => {
	let owned!: PrivateViewStore; const ownedRoot = await mkdtemp(path.join(os.tmpdir(), "tmux-subagents-owned-race-")); owned = new PrivateViewStore(ownedRoot, "session-1", "owned", { beforeLeaseTransition: async (kind) => { if (kind === "remove-owned") await writeFile(owned.leasePath, `${JSON.stringify({ schemaVersion: 1, generation: owned.generation, pid: process.pid, ownerToken: "F".repeat(32), processStartIdentity: "linux:foreign", startedAt: 1 })}\n`, { mode: 0o600 }); } }); await owned.initialize(); await assert.rejects(owned.removeOwnedGeneration(), /changed during owned removal/); assert.equal(JSON.parse(await readFile(owned.leasePath, "utf8")).ownerToken, "F".repeat(32));
	let stale!: PrivateViewStore; const staleRoot = await mkdtemp(path.join(os.tmpdir(), "tmux-subagents-stale-race-")); stale = new PrivateViewStore(staleRoot, "session-1", "stale", { beforeLeaseTransition: async (kind) => { if (kind === "remove-stale") await writeFile(stale.leasePath, `${JSON.stringify({ schemaVersion: 1, generation: stale.generation, pid: 2147483647, ownerToken: "N".repeat(32), processStartIdentity: "linux:new", released: true, startedAt: 1 })}\n`, { mode: 0o600 }); } }); await stale.initialize(); await stale.releaseLease(); const proof = await stale.reapLease(); if (proof.status !== "stale") throw new Error("expected stale proof"); await assert.rejects(stale.removeStaleGeneration(proof.ownerToken, proof.processStartIdentity), /changed during stale removal/); assert.equal(JSON.parse(await readFile(stale.leasePath, "utf8")).ownerToken, "N".repeat(32));
});

test("generation leases refuse active reaping and require proven-dead ownership", posixOnly, async () => {
	const { store } = await storeFixture(); assert.equal((await store.reapLease()).status, "active");
	await writeFile(store.leasePath, `${JSON.stringify({ schemaVersion: 1, generation: store.generation, pid: process.pid, ownerToken: "A".repeat(32), processStartIdentity: "linux:reused-pid", startedAt: 1 })}\n`, { mode: 0o600 }); assert.equal((await store.reapLease()).status, "stale", "PID reuse was mistaken for the original process");
	await writeFile(store.leasePath, `${JSON.stringify({ schemaVersion: 1, generation: store.generation, pid: 2147483647, ownerToken: "A".repeat(32), processStartIdentity: "linux:stale", startedAt: 1 })}\n`, { mode: 0o600 });
	assert.equal((await store.reapLease()).status, "stale"); await assert.rejects(store.removeStaleGeneration("B".repeat(32), "linux:stale"), /changed or is not proven stale/); assert.ok(await stat(store.generationRoot));
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
