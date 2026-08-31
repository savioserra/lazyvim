import test from "node:test";
import assert from "node:assert/strict";
import { ClientMutationSequenceError, ClientMutationSequencer, isClientSequenceFailure } from "../../home/dot_pi/private_agent/extensions/hosted-pi-bridge/mutations.ts";

const fast = { retries: 2, cooldownMs: () => 0 };
const binding = { endpoint: "ws://127.0.0.1:17213/actors", sessionId: "session-1", generationId: "generation-1", caller: "hosted:agent-a", agentId: "agent-a", runtimeId: "runtime-a", incarnation: 1n, credential: new Uint8Array(32) };
const token = `${binding.sessionId}\0${binding.generationId}\0${binding.caller}\0${binding.agentId}`;
const messageScope = `${token}\0messages`;
const message = (sequence) => ({ requestId: `request-${sequence}`, value: { target: "peer", dedupeId: `dedupe-${sequence}`, chainId: `chain-${sequence}`, sourceMutationSequence: sequence } });

test("second peer message advances 2,3 in one hosted-bridge message namespace", async () => {
  const sequencer = new ClientMutationSequencer(fast);
  const sequences = [];
  for (const peer of ["peer-alpha", "peer-beta", "peer-gamma"]) {
    const receipt = await sequencer.run(messageScope, message, async (logical) => { sequences.push({ peer, sequence: logical.value.sourceMutationSequence }); return { accepted: true }; }, async () => {});
    assert.equal(receipt.accepted, true);
  }
  assert.deepEqual(sequences.map((item) => item.sequence), [1n, 2n, 3n]);
  assert.deepEqual(sequences.map((item) => item.peer), ["peer-alpha", "peer-beta", "peer-gamma"]);
});

test("concurrent multi-peer sends queue behind the unresolved mutation and all settle in order", async () => {
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
    sequencer.run(messageScope, message, attempt, async () => {}),
    sequencer.run(messageScope, message, attempt, async () => {}),
    sequencer.run(messageScope, message, attempt, async () => {}),
  ]);
  assert.deepEqual(receipts.map((receipt) => receipt.accepted), [true, true, true]);
  assert.equal(maxInFlight, 1, "allocations must be serialized per scope");
  assert.deepEqual(events, ["start:1", "end:1", "start:2", "end:2", "start:3", "end:3"]);
});

test("reconnect replays the immutable request and resumes at high-water+1", async () => {
  const sequencer = new ClientMutationSequencer({ retries: 5, cooldownMs: () => 0 });
  const first = await sequencer.run(messageScope, message, async () => ({ accepted: true }), async () => {});
  assert.equal(first.accepted, true);
  let reconciliations = 0;
  const attempts = [];
  const second = await sequencer.run(messageScope, message, async (logical) => {
    attempts.push(structuredClone(logical));
    if (attempts.length === 1) throw new Error("daemon websocket error");
    return { accepted: true };
  }, async () => { reconciliations++; });
  assert.equal(second.accepted, true);
  assert.equal(reconciliations, 1, "reconnect reconcile runs between retries");
  assert.equal(attempts.length, 2, "the retained mutation replays instead of allocating a new sequence");
  assert.deepEqual(attempts[0], attempts[1], "the unresolved logical request stays immutable across reconnect");
  assert.equal(attempts[0].value.sourceMutationSequence, 2n);
  const third = await sequencer.run(messageScope, message, async (logical) => { assert.equal(logical.value.sourceMutationSequence, 3n); return { accepted: true }; }, async () => {});
  assert.equal(third.accepted, true);
});

test("a true sequence collision fails loud without retry and keeps the high-water", async () => {
  const sequencer = new ClientMutationSequencer(fast);
  await sequencer.run(messageScope, message, async () => ({ accepted: true }), async () => {});
  let attempts = 0;
  await assert.rejects(
    sequencer.run(messageScope, message, async () => { attempts++; return { accepted: false, reason: "source mutation sequence collision" }; }, async () => {}),
    (error) => error instanceof ClientMutationSequenceError && error.sequence === 2n && /source mutation sequence collision/.test(error.daemonReason),
  );
  assert.equal(attempts, 1, "collision receipts must not be retried");
  const next = await sequencer.run(messageScope, message, async (logical) => { assert.equal(logical.value.sourceMutationSequence, 2n); return { accepted: true }; }, async () => {});
  assert.equal(next.accepted, true, "an un-admitted sequence stays available after a loud failure");
});

test("control scopes stay per-target while messages share one namespace", async () => {
  const sequencer = new ClientMutationSequencer(fast);
  const control = (sequence) => ({ requestId: `control-${sequence}`, value: { intent: 1, sourceMutationSequence: sequence } });
  const alphaScope = `${token}\0control\0handle-alpha\0${1n}`;
  const betaScope = `${token}\0control\0handle-beta\0${1n}`;
  const alphaFirst = await sequencer.run(alphaScope, control, async (logical) => ({ accepted: true, sequence: logical.value.sourceMutationSequence }), async () => {});
  const betaFirst = await sequencer.run(betaScope, control, async (logical) => ({ accepted: true, sequence: logical.value.sourceMutationSequence }), async () => {});
  const alphaSecond = await sequencer.run(alphaScope, control, async (logical) => ({ accepted: true, sequence: logical.value.sourceMutationSequence }), async () => {});
  const messageFirst = await sequencer.run(messageScope, message, async (logical) => ({ accepted: true, sequence: logical.value.sourceMutationSequence }), async () => {});
  assert.deepEqual([alphaFirst.sequence, betaFirst.sequence, alphaSecond.sequence, messageFirst.sequence], [1n, 1n, 2n, 1n]);
});

test("transport failures retry a bounded number of times with cooldown before failing", async () => {
  const cooldowns = [];
  const sequencer = new ClientMutationSequencer({ retries: 3, cooldownMs: (attempt) => { cooldowns.push(attempt); return 0; } });
  let attempts = 0;
  let reconciliations = 0;
  await assert.rejects(
    sequencer.run(messageScope, message, async () => { attempts++; throw new Error("daemon response deadline expired"); }, async () => { reconciliations++; }),
    /daemon response deadline expired/,
  );
  assert.equal(attempts, 4);
  assert.equal(reconciliations, 4);
  assert.deepEqual(cooldowns, [0, 1, 2]);
});

test("session-shutdown retirement drops message and control scopes together", async () => {
  const sequencer = new ClientMutationSequencer(fast);
  await sequencer.run(messageScope, message, async () => ({ accepted: true }), async () => {});
  await sequencer.run(`${token}\0control\0handle-alpha\0${1n}`, (sequence) => ({ value: { sourceMutationSequence: sequence } }), async () => ({ accepted: true }), async () => {});
  assert.equal(sequencer.retireScopes(token), 2, "retirement covers the shared message scope and per-target control scopes");
  const restarted = await sequencer.run(messageScope, message, async (logical) => { assert.equal(logical.value.sourceMutationSequence, 1n); return { accepted: true }; }, async () => {});
  assert.equal(restarted.accepted, true);
});

test("sequence failure classification covers the daemon rejection family", () => {
  for (const reason of ["source mutation sequence collision", "source mutation sequence must advance exactly once", "source mutation sequence is at or below the retired high-water mark"]) assert.equal(isClientSequenceFailure(reason), true);
  assert.equal(isClientSequenceFailure("target hosted bridge is not ready"), false);
  assert.equal(isClientSequenceFailure(undefined), false);
});
