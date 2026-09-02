import test from "node:test";
import assert from "node:assert/strict";
import { createActor } from "../../home/dot_pi/private_agent/extensions/actor-client/node_modules/xstate/dist/xstate.cjs.js";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { actorClientProjectionMachine, initialProjectionContext, reduceProjection } from "../../home/dot_pi/private_agent/extensions/actor-client/projections/machine.ts";
import { canonicalCompletionKey, digestPresentation } from "../../home/dot_pi/private_agent/extensions/actor-client/projections/dedupe.ts";
import { renderPlainCard } from "../../home/dot_pi/private_agent/extensions/actor-client/projections/layout.ts";

const testDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(testDir, "../../home/dot_pi/private_agent/extensions/actor-client");

test("actor-client owns exact xstate 5.20.2 package and integrity pin", async () => {
  const manifest = JSON.parse(await readFile(`${root}/package.json`, "utf8"));
  const lock = JSON.parse(await readFile(`${root}/package-lock.json`, "utf8"));
  assert.equal(manifest.dependencies.xstate, "5.20.2");
  assert.equal(lock.packages[""].dependencies.xstate, "5.20.2");
  assert.equal(lock.packages["node_modules/xstate"].version, "5.20.2");
  assert.equal(lock.packages["node_modules/xstate"].integrity, "sha512-GZmLmc+WPKfFRxuTDAxCg0cUhS/ZnWaRD86DO8MKizeK4a050jd5k7UNnIQ2jJDWRig2/r0tmVXeezUNIhoz5Q==");
});

test("root xstate actor applies transactional roster reset duplicate and gap fencing", () => {
  const actor = createActor(actorClientProjectionMachine).start();
  actor.send({ type: "TRANSPORT.CONNECTED" });
  actor.send({ type: "ROSTER.FRAME", frame: { operation: 2, epoch: 1n, sequence: 1n } });
  actor.send({ type: "ROSTER.FRAME", frame: { operation: 3, epoch: 1n, sequence: 2n, agentId: "a", agent: { agentId: "a", displayName: "Alpha", hostedPiRuntime: { state: 3 } } } });
  actor.send({ type: "ROSTER.FRAME", frame: { operation: 3, epoch: 1n, sequence: 2n, agentId: "b", agent: { agentId: "b", displayName: "Beta", hostedPiRuntime: { state: 3 } } } });
  assert.equal(actor.getSnapshot().context.roster.agents.size, 1);
  actor.send({ type: "ROSTER.FRAME", frame: { operation: 3, epoch: 1n, sequence: 4n, agentId: "c", agent: { agentId: "c", displayName: "Gamma" } } });
  assert.match(actor.getSnapshot().context.snapshot.statusLine, /degraded/);
  actor.send({ type: "ROSTER.FRAME", frame: { operation: 2, epoch: 2n, sequence: 1n } });
  assert.equal(actor.getSnapshot().context.roster.agents.size, 0);
  assert.equal(actor.getSnapshot().context.roster.epoch, 2n);
});

test("completion transaction clears hidden pending and collision fails closed", () => {
  let context = initialProjectionContext();
  context = reduceProjection(context, { type: "TASK.ADMITTED", pending: { key: "k1", requestId: "r1", dedupeId: "d1", chainId: "c1", sourceMutationSequence: "1", target: "Reviewer", kind: "Ask", prompt: "secret credential=abc?", hidden: true } });
  assert.equal(context.pending.size, 1);
  context = reduceProjection(context, { type: "TASK.COMPLETED", key: "k1", reply: "answer", completed: true, requestId: "r1", dedupeId: "d1", chainId: "c1", sourceMutationSequence: "1", target: "Reviewer" });
  assert.equal(context.pending.size, 0);
  assert.equal(context.cards.get("k1").state, "replied");
  assert.throws(() => reduceProjection(context, { type: "TASK.COMPLETED", key: "k1", reply: "different", completed: true, requestId: "r1", dedupeId: "d1", chainId: "c1", sourceMutationSequence: "1", target: "Reviewer" }), /completion key collision/);
});

test("admission receipt does not complete; completion authority renders once", () => {
  let context = reduceProjection(initialProjectionContext(), { type: "TASK.ADMITTED", pending: { key: "ask", requestId: "r", dedupeId: "d", chainId: "c", sourceMutationSequence: "8", target: "Reviewer", kind: "Ask", prompt: "question", hidden: true } });
  assert.equal(context.snapshot.cards.length, 0);
  context = reduceProjection(context, { type: "TASK.COMPLETED", key: "ask", reply: "result", completed: true, requestId: "r", dedupeId: "d", chainId: "c", sourceMutationSequence: "8", target: "Reviewer" });
  const duplicate = reduceProjection(context, { type: "TASK.COMPLETED", key: "ask", reply: "result", completed: true, requestId: "r", dedupeId: "d", chainId: "c", sourceMutationSequence: "8", target: "Reviewer" });
  assert.equal(duplicate.snapshot.cards.length, 1);
});

test("responsive card rendering is bounded and resize idempotent", () => {
  const context = reduceProjection(initialProjectionContext(), { type: "DELIVERY.INCOMING.NOTE", key: "n", source: { displayName: "Project Manager", role: "PM", authoritative: true }, body: "please verify\n".repeat(80) });
  const card = context.snapshot.cards[0];
  const narrow = renderPlainCard(card, 40);
  const wide = renderPlainCard(card, 90);
  assert.ok(narrow.every((line) => line.length <= 40));
  assert.ok(wide.every((line) => line.length <= 90));
  const resized = reduceProjection(context, { type: "VIEW.WIDTH", width: 40 });
  assert.equal(resized.snapshot.cards.length, 1);
});

test("canonical completion keys prefer daemon keys and digest migration identity", () => {
  assert.equal(canonicalCompletionKey({ completionKey: "daemon-key" }), "daemon-key");
  const key = canonicalCompletionKey({ target: "target", source: "source", requestId: "r", dedupeId: "d", chainId: "c", sourceMutationSequence: 9n });
  assert.equal(key.length, 64);
  assert.equal(digestPresentation({ x: 1n }).length, 64);
});
