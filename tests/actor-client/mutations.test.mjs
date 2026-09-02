import test from "node:test";
import assert from "node:assert/strict";
import { ClientMutationSequenceError, ClientMutationSequencer, isClientSequenceFailure } from "../../home/dot_pi/private_agent/extensions/actor-client/mutations.ts";

const fast = { retries: 2, cooldownMs: () => 0 };
const tell = (sequence) => ({ requestId: `request-${sequence}`, value: { target: "alpha", dedupeId: `dedupe-${sequence}`, chainId: `chain-${sequence}`, sourceMutationSequence: sequence } });

test("sequential tells advance 1,2,3 across different targets in one client-peer scope", async () => {
  const sequencer = new ClientMutationSequencer(fast);
  const sequences = [];
  for (const target of ["alpha", "beta", "gamma"]) {
    const receipt = await sequencer.run("peer:client:one/messages", tell, async (logical) => { sequences.push({ target, sequence: logical.value.sourceMutationSequence }); return { accepted: true }; }, async () => {});
    assert.equal(receipt.accepted, true);
  }
  assert.deepEqual(sequences.map((item) => item.sequence), [1n, 2n, 3n]);
  assert.deepEqual(sequences.map((item) => item.target), ["alpha", "beta", "gamma"]);
});

test("concurrent tells queue behind the unresolved mutation and all settle in order", async () => {
  const sequencer = new ClientMutationSequencer(fast);
  const events = [];
  let inFlight = 0;
  let maxInFlight = 0;
  const attempt = async (logical) => {
    inFlight++; maxInFlight = Math.max(maxInFlight, inFlight);
    events.push(`start:${logical.value.sourceMutationSequence}`);
    await new Promise((resolve) => setTimeout(resolve, 5));
    events.push(`end:${logical.value.sourceMutationSequence}`);
    inFlight--;
    return { accepted: true };
  };
  const receipts = await Promise.all([
    sequencer.run("peer:client:one/messages", tell, attempt, async () => {}),
    sequencer.run("peer:client:one/messages", tell, attempt, async () => {}),
    sequencer.run("peer:client:one/messages", tell, attempt, async () => {}),
  ]);
  assert.deepEqual(receipts.map((receipt) => receipt.accepted), [true, true, true]);
  assert.equal(maxInFlight, 1, "allocations must be serialized per scope");
  assert.deepEqual(events, ["start:1", "end:1", "start:2", "end:2", "start:3", "end:3"]);
});

test("transport failure retains and replays the immutable unresolved request, then resumes at high-water+1", async () => {
  const sequencer = new ClientMutationSequencer({ retries: 5, cooldownMs: () => 0 });
  const first = await sequencer.run("peer:client:one/messages", tell, async () => ({ accepted: true }), async () => {});
  assert.equal(first.accepted, true);
  let reconciliations = 0;
  const attempts = [];
  const second = await sequencer.run("peer:client:one/messages", tell, async (logical) => {
    attempts.push(structuredClone(logical));
    if (attempts.length === 1) throw new Error("client daemon disconnected");
    return { accepted: true };
  }, async () => { reconciliations++; });
  assert.equal(second.accepted, true);
  assert.equal(reconciliations, 1, "reconnect reconcile runs between retries");
  assert.equal(attempts.length, 2, "the retained mutation replays instead of allocating a new sequence");
  assert.deepEqual(attempts[0], attempts[1], "the unresolved logical request stays immutable across reconnect");
  assert.equal(attempts[0].value.sourceMutationSequence, 2n);
  const third = await sequencer.run("peer:client:one/messages", tell, async (logical) => { assert.equal(logical.value.sourceMutationSequence, 3n); return { accepted: true }; }, async () => {});
  assert.equal(third.accepted, true);
});

test("a retired session scope restarts at 1 while untouched scopes keep advancing", async () => {
  const sequencer = new ClientMutationSequencer(fast);
  await sequencer.run("peer:client:old/messages", tell, async () => ({ accepted: true }), async () => {});
  await sequencer.run("peer:client:kept/messages", tell, async () => ({ accepted: true }), async () => {});
  const retired = sequencer.retireScopes("peer:client:old");
  assert.equal(retired, 1);
  const reloaded = await sequencer.run("peer:client:new/messages", tell, async (logical) => { assert.equal(logical.value.sourceMutationSequence, 1n); return { accepted: true }; }, async () => {});
  assert.equal(reloaded.accepted, true);
  const continued = await sequencer.run("peer:client:kept/messages", tell, async (logical) => { assert.equal(logical.value.sourceMutationSequence, 2n); return { accepted: true }; }, async () => {});
  assert.equal(continued.accepted, true);
});

test("a true sequence collision fails loud without retry and keeps the high-water", async () => {
  const sequencer = new ClientMutationSequencer(fast);
  await sequencer.run("peer:client:one/messages", tell, async () => ({ accepted: true }), async () => {});
  let attempts = 0;
  await assert.rejects(
    sequencer.run("peer:client:one/messages", tell, async () => { attempts++; return { accepted: false, reason: "source mutation sequence collision" }; }, async () => {}),
    (error) => error instanceof ClientMutationSequenceError && error.sequence === 2n && /source mutation sequence collision/.test(error.daemonReason) && /peer:client:one\/messages/.test(error.message),
  );
  assert.equal(attempts, 1, "collision receipts must not be retried");
  const next = await sequencer.run("peer:client:one/messages", tell, async (logical) => { assert.equal(logical.value.sourceMutationSequence, 2n); return { accepted: true }; }, async () => {});
  assert.equal(next.accepted, true, "an un-admitted sequence stays available after a loud failure");
});

test("transport failures retry a bounded number of times with cooldown before failing", async () => {
  const cooldowns = [];
  const sequencer = new ClientMutationSequencer({ retries: 3, cooldownMs: (attempt) => { cooldowns.push(attempt); return 0; } });
  let attempts = 0;
  let reconciliations = 0;
  await assert.rejects(
    sequencer.run("peer:client:one/messages", tell, async () => { attempts++; throw new Error("client response timeout"); }, async () => { reconciliations++; }),
    /client response timeout/,
  );
  assert.equal(attempts, 4);
  assert.equal(reconciliations, 4);
  assert.deepEqual(cooldowns, [0, 1, 2]);
});

test("sequence failure classification covers the daemon rejection family", () => {
  for (const reason of ["source mutation sequence collision", "source mutation sequence must advance exactly once", "source mutation sequence is at or below the retired high-water mark"]) assert.equal(isClientSequenceFailure(reason), true);
  assert.equal(isClientSequenceFailure("target delivery backlog is full"), false);
  assert.equal(isClientSequenceFailure(undefined), false);
});

test("control scopes stay independent per target fence while sharing one session token", async () => {
  const sequencer = new ClientMutationSequencer(fast);
  const control = (sequence) => ({ requestId: `control-${sequence}`, value: { intent: 1, sourceMutationSequence: sequence } });
  const alphaFirst = await sequencer.run("peer:client:one/control/handle-a/1", control, async (logical) => ({ accepted: true, sequence: logical.value.sourceMutationSequence }), async () => {});
  const betaFirst = await sequencer.run("peer:client:one/control/handle-b/1", control, async (logical) => ({ accepted: true, sequence: logical.value.sourceMutationSequence }), async () => {});
  const alphaSecond = await sequencer.run("peer:client:one/control/handle-a/1", control, async (logical) => ({ accepted: true, sequence: logical.value.sourceMutationSequence }), async () => {});
  assert.deepEqual([alphaFirst.sequence, betaFirst.sequence, alphaSecond.sequence], [1n, 1n, 2n]);
  assert.equal(sequencer.retireScopes("peer:client:one"), 2, "session retirement covers message and control scopes");
});

test("adoptHighWater floors the allocator from drained daemon completions", async () => {
  const sequencer = new ClientMutationSequencer(fast);
  sequencer.adoptHighWater("client:term-stable\0messages", 0n);
  let receipt = await sequencer.run("client:term-stable\0messages", tell, async (logical) => { assert.equal(logical.value.sourceMutationSequence, 1n); return { accepted: true }; }, async () => {});
  assert.equal(receipt.accepted, true);
  sequencer.adoptHighWater("client:term-stable\0messages", 7n);
  receipt = await sequencer.run("client:term-stable\0messages", tell, async (logical) => { assert.equal(logical.value.sourceMutationSequence, 8n, "reloaded allocator resumes above the drained floor"); return { accepted: true }; }, async () => {});
  assert.equal(receipt.accepted, true);
  sequencer.adoptHighWater("client:term-stable\0messages", 3n);
  receipt = await sequencer.run("client:term-stable\0messages", tell, async (logical) => { assert.equal(logical.value.sourceMutationSequence, 9n, "a lower floor never rewinds the high-water"); return { accepted: true }; }, async () => {});
  assert.equal(receipt.accepted, true);
});

test("client OPEN adopts the daemon high-water before the first post-reload allocation", async () => {
  const { adoptClientSessionMutationHighWater, clientMessageScopeKey } = await import("../../home/dot_pi/private_agent/extensions/actor-client/index.ts");
  const sequencer = new ClientMutationSequencer(fast);
  adoptClientSessionMutationHighWater(sequencer, "client:term-stable", 10n);
  const receipt = await sequencer.run(clientMessageScopeKey("client:term-stable"), tell, async (logical) => ({ accepted: true, sequence: logical.value.sourceMutationSequence }), async () => {});
  assert.equal(receipt.sequence, 11n);
});

test("message scope keys to the stable terminal caller across session churn", async () => {
  const { clientMessageScopeKey, clientControlScopeKey, terminalClientIdentity } = await import("../../home/dot_pi/private_agent/extensions/actor-client/index.ts");
  const first = { sessionId: "session-a", generationId: "generation-a", caller: "client:term-stable", credential: new Uint8Array() };
  const second = { sessionId: "session-b", generationId: "generation-b", caller: "client:term-stable", credential: new Uint8Array() };
  assert.equal(clientMessageScopeKey(first.caller), clientMessageScopeKey(second.caller), "a re-OPEN under the same terminal identity keeps one daemon namespace");
  const fenceA = { handle: "handle-a", fence: 1n };
  const fenceB = { handle: "handle-b", fence: 1n };
  assert.notEqual(clientControlScopeKey(first, fenceA), clientControlScopeKey(second, fenceA), "control scopes stay per session");
  assert.notEqual(clientControlScopeKey(first, fenceA), clientControlScopeKey(first, fenceB), "control scopes stay per target fence");
  assert.equal(terminalClientIdentity("pi-session-42"), "pi-session-42");
  assert.equal(terminalClientIdentity("unicode-é-session"), "7115f1b3bfa1c08fc2ec96e02cf1ce09d07db4ba");
  assert.equal(terminalClientIdentity(""), "");
  assert.equal(terminalClientIdentity(undefined), "");
  assert.ok(terminalClientIdentity("x".repeat(64)).length <= 40 && /^[A-Za-z0-9_-]{1,48}$/.test(terminalClientIdentity("x".repeat(64))));
});
