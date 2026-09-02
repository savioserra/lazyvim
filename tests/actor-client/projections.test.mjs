import test from "node:test";
import assert from "node:assert/strict";
import { createActor } from "../../home/dot_pi/private_agent/extensions/actor-client/node_modules/xstate/dist/xstate.cjs.js";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { actorClientProjectionMachine, initialProjectionContext, reduceProjection, restoreProjectionEntries } from "../../home/dot_pi/private_agent/extensions/actor-client/projections/machine.ts";
import { canonicalCompletionKey, digestPresentation } from "../../home/dot_pi/private_agent/extensions/actor-client/projections/dedupe.ts";
import { renderPlainCard } from "../../home/dot_pi/private_agent/extensions/actor-client/projections/layout.ts";
import { conversationEnvelope, envelopeFromLegacy } from "../../home/dot_pi/private_agent/extensions/actor-client/projections/render-envelope.ts";
import { renderActorClientConversationEnvelope } from "../../home/dot_pi/private_agent/extensions/actor-client/widgets/conversation-card.ts";
import { selectPendingStatusLine } from "../../home/dot_pi/private_agent/extensions/actor-client/projections/selectors.ts";

const testDir = dirname(fileURLToPath(import.meta.url));
const root = resolve(testDir, "../../home/dot_pi/private_agent/extensions/actor-client");

test("actor-client owns exact xstate 5.20.2 package and integrity pin", async () => {
  const manifest = JSON.parse(await readFile(`${root}/package.json`, "utf8"));
  const lock = JSON.parse(await readFile(`${root}/package-lock.json`, "utf8"));
  assert.equal(manifest.dependencies.xstate, "5.20.2");
  assert.equal(lock.packages[""].dependencies.xstate, "5.20.2");
  assert.equal(lock.packages["node_modules/xstate"].version, "5.20.2");
  assert.equal(lock.packages["node_modules/xstate"].integrity, "sha512-GZmLmc+WPKfFRxuTDAxCg0cUhS/ZnWaRD86DO8MKizeK4a050jd5k7UNnIQ2jJDWRig2/r0tmVXeezUNIhoz5Q==");
  const versions = JSON.parse(await readFile(resolve(testDir, "../../home/dot_local/share/workstation/versions.json"), "utf8"));
  assert.equal(versions.actor_client_xstate, "5.20.2");
  assert.equal(versions.xstate, "5.32.6");
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

test("higher roster epoch upsert/remove without reset degrades without applying", () => {
  let context = reduceProjection(initialProjectionContext(), { type: "TRANSPORT.CONNECTED" });
  context = reduceProjection(context, { type: "ROSTER.FRAME", frame: { operation: 2, epoch: 1n, sequence: 1n } });
  context = reduceProjection(context, { type: "ROSTER.FRAME", frame: { operation: 3, epoch: 1n, sequence: 2n, agentId: "a", agent: { agentId: "a", displayName: "Alpha" } } });
  context = reduceProjection(context, { type: "ROSTER.FRAME", frame: { operation: 3, epoch: 2n, sequence: 1n, agentId: "b", agent: { agentId: "b", displayName: "Beta" } } });
  assert.equal(context.roster.epoch, 1n);
  assert.equal(context.roster.agents.has("b"), false);
  assert.match(context.snapshot.statusLine, /degraded/);
});

test("completion transaction clears hidden pending and collision fails closed", () => {
  let context = initialProjectionContext();
  context = reduceProjection(context, { type: "TASK.ADMITTED", pending: { key: "k1", requestId: "r1", dedupeId: "d1", chainId: "c1", sourceMutationSequence: "1", target: "Reviewer", kind: "Ask", prompt: "secret credential=abc?", hidden: true } });
  assert.equal(context.pending.size, 1);
  context = reduceProjection(context, { type: "TASK.COMPLETED", key: "daemon-completion-key", reply: "answer", completed: true, requestId: "r1", dedupeId: "d1", chainId: "c1", sourceMutationSequence: "1", target: "Reviewer" });
  assert.equal(context.pending.size, 0);
  assert.equal(context.cards.get("daemon-completion-key").state, "replied");
  assert.equal(context.cards.get("daemon-completion-key").body, "[redacted] [redacted]?");
  assert.throws(() => reduceProjection(context, { type: "TASK.COMPLETED", key: "daemon-completion-key", reply: "different", completed: true, requestId: "r1", dedupeId: "d1", chainId: "c1", sourceMutationSequence: "1", target: "Reviewer" }), /completion key collision/);
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

test("persisted restore applies terminal-wins order and clears provisional pending", () => {
  const context = restoreProjectionEntries(initialProjectionContext(), [
    { type: "message", message: { customType: "actor-client-ask-completion", details: { key: "canonical", requestId: "request-7", terminal: "replied", answer: "done" } } },
    { type: "custom", customType: "actor-client-ask-pending", data: { key: "actor-client:request-7", requestId: "request-7", dedupeId: "d", chainId: "c", sourceMutationSequence: "7", target: "Reviewer", kind: "Ask", prompt: "old", hidden: true } },
  ]);
  assert.equal(context.pending.size, 0);
  assert.equal(context.completions.has("canonical"), true);
});

test("render envelope widgets are width aware, theme driven, and resize-idempotent", () => {
  const card = { key: "tell", direction: "outgoing", intent: "note", state: "delivered", peerDisplayName: "Code Reviewer", peerRole: "review", body: "The implementation is ready for review." };
  const calls = [];
  const theme = { fg: (name, text) => (calls.push(name), text), bg: (_name, text) => text };
  const component = renderActorClientConversationEnvelope(conversationEnvelope(card), theme);
  const narrow = component.render(38);
  component.invalidate();
  const wide = component.render(82);
  assert.ok(narrow.every((line) => line.length <= 38));
  assert.ok(wide.every((line) => line.length <= 82));
  assert.match(wide.join("\n"), /↑ Sent to Code Reviewer · review/);
  assert.match(wide.join("\n"), /╰─ ✓ delivered/);
  assert.ok(calls.includes("blue") || calls.includes("toolTitle"));
});

test("legacy communication migration is read-only and renders through envelope widget", () => {
  const legacy = Object.freeze({ key: "legacy", direction: "incoming", intent: "request", state: "pending", peerDisplayName: "Project Manager", peerRole: "", body: "Review this" });
  const envelope = envelopeFromLegacy({ communicationView: legacy });
  assert.equal(envelope.schemaVersion, 1);
  assert.equal(envelope.renderSnapshot.card.key, "legacy");
  assert.equal(legacy.state, "pending");
  const lines = renderActorClientConversationEnvelope(envelope, { fg: (_name, text) => text, bg: (_name, text) => text }).render(50).join("\n");
  assert.match(lines, /Project Manager asked you/);
  assert.match(lines, /Waiting for Project Manager…/);
});

test("pending status selector uses approved single-ask wording", () => {
  const context = reduceProjection(initialProjectionContext(), { type: "TASK.ADMITTED", pending: { key: "ask", requestId: "r", dedupeId: "d", chainId: "c", sourceMutationSequence: "1", target: "Code Reviewer", kind: "Ask", prompt: "question", hidden: true } });
  assert.equal(selectPendingStatusLine(context), "◌ Waiting for Code Reviewer…");
});

test("canonical completion keys prefer daemon keys and digest migration identity", () => {
  assert.equal(canonicalCompletionKey({ completionKey: "daemon-key" }), "daemon-key");
  const key = canonicalCompletionKey({ target: "target", source: "source", requestId: "r", dedupeId: "d", chainId: "c", sourceMutationSequence: 9n });
  assert.equal(key.length, 64);
  assert.equal(digestPresentation({ x: 1n }).length, 64);
});
