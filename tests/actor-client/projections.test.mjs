import test from "node:test";
import assert from "node:assert/strict";
import { createActor } from "../../home/dot_pi/private_agent/extensions/actor-client/node_modules/xstate/dist/xstate.cjs.js";
import { visibleWidth } from "../../home/dot_pi/private_agent/extensions/actor-client/node_modules/@earendil-works/pi-tui/dist/index.js";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { actorClientProjectionMachine, initialProjectionContext, reduceProjection, restoreProjectionEntries } from "../../home/dot_pi/private_agent/extensions/actor-client/projections/machine.ts";
import { adaptActorActivityFrame } from "../../home/dot_pi/private_agent/extensions/actor-client/projections/activity.ts";
import { canonicalCompletionKey, digestPresentation } from "../../home/dot_pi/private_agent/extensions/actor-client/projections/dedupe.ts";
import { renderPlainCard } from "../../home/dot_pi/private_agent/extensions/actor-client/projections/layout.ts";
import { conversationEnvelope, envelopeFromLegacy } from "../../home/dot_pi/private_agent/extensions/actor-client/projections/render-envelope.ts";
import { renderActorClientConversationEnvelope } from "../../home/dot_pi/private_agent/extensions/actor-client/widgets/conversation-card.ts";
import { selectActorUiSnapshot, selectPendingStatusLine } from "../../home/dot_pi/private_agent/extensions/actor-client/projections/selectors.ts";
import { ActorStatusOverlay, renderActorStatusFallback } from "../../home/dot_pi/private_agent/extensions/actor-client/widgets/actor-status-overlay.ts";

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

test("ansi themed cards stay display-width bounded and semantically intact", () => {
  const card = { key: "ansi", direction: "incoming", intent: "request", state: "pending", peerDisplayName: "Project Manager", peerRole: "coordination", body: "Review the production widget wiring and report blockers." };
  const theme = { fg: (_name, text) => `\x1b[35m${text}\x1b[0m`, bg: (_name, text) => `\x1b[48;5;236m${text}\x1b[0m` };
  const component = renderActorClientConversationEnvelope(conversationEnvelope(card), theme);
  for (const width of [20, 25, 49, 80]) {
    const lines = component.render(width);
    assert.ok(lines.every((line) => visibleWidth(line) <= width), `line exceeded ${width}: ${JSON.stringify(lines)}`);
    assert.ok(lines.every((line) => !line.replace(/\x1b\[[0-9;]*m/g, "").includes("\x1b")), "broken ANSI control sequence");
    const plain = lines.join("\n").replace(/\x1b\[[0-9;]*m/g, "");
    assert.match(plain, /↓/);
    assert.match(plain, /Project|Manager|asked|you/);
    assert.match(plain, /Waiting|Project/);
  }
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

test("actor status snapshot fences activity epochs sequences gaps resets and clear separately from lifecycle", () => {
  let context = reduceProjection(initialProjectionContext(), { type: "TRANSPORT.CONNECTED" });
  context = reduceProjection(context, { type: "ROSTER.FRAME", frame: { operation: 2, epoch: 1n, sequence: 1n } });
  context = reduceProjection(context, { type: "ROSTER.FRAME", frame: { operation: 3, epoch: 1n, sequence: 2n, agentId: "a", agent: { agentId: "a", displayName: "Alpha", hostedPiRuntime: { state: 3 } } } });
  context = reduceProjection(context, { type: "ACTIVITY.FRAME", frame: { operation: "reset", epoch: 1n, sequence: 1n, agentId: "a", threadId: "t0" } });
  context = reduceProjection(context, { type: "ACTIVITY.FRAME", frame: { operation: "upsert", epoch: 1n, sequence: 2n, agentId: "a", threadId: "t1", label: "review_code", pending: true } });
  assert.equal(selectActorUiSnapshot(context).rows[0].lifecycle, "ready");
  assert.equal(selectActorUiSnapshot(context).rows[0].activity, "Review Code");
  assert.equal(selectActorUiSnapshot(context).rows[0].pending, true);
  const reconnecting = reduceProjection(context, { type: "TRANSPORT.RECONNECTING" });
  const stale = reduceProjection(reconnecting, { type: "ACTIVITY.FRAME", frame: { operation: "upsert", epoch: 1n, sequence: 2n, agentId: "a", threadId: "old", label: "stale" } });
  assert.equal(selectActorUiSnapshot(stale).rows[0].activity, undefined);
  const gapped = reduceProjection(context, { type: "ACTIVITY.FRAME", frame: { operation: "upsert", epoch: 1n, sequence: 4n, agentId: "a", threadId: "gap", label: "gap" } });
  assert.match(gapped.snapshot.actorStatus.footer, /degraded|ready/);
  const cleared = reduceProjection(context, { type: "ACTIVITY.CLEAR", agentId: "a", threadId: "t1", epoch: 1n, sequence: 3n });
  assert.equal(selectActorUiSnapshot(cleared).rows[0].lifecycle, "ready");
  assert.equal(selectActorUiSnapshot(cleared).rows[0].activity, undefined);
});

test("reconnect and subscribing states never flash retained rows as live before reset replay", () => {
  let context = reduceProjection(initialProjectionContext(), { type: "TRANSPORT.CONNECTED" });
  context = reduceProjection(context, { type: "ROSTER.FRAME", frame: { operation: 2, epoch: 1n, sequence: 1n } });
  context = reduceProjection(context, { type: "ROSTER.FRAME", frame: { operation: 3, epoch: 1n, sequence: 2n, agentId: "a", agent: { agentId: "a", displayName: "Alpha", hostedPiRuntime: { state: 3 } } } });
  context = reduceProjection(context, { type: "ACTIVITY.FRAME", frame: { operation: "reset", epoch: 1n, sequence: 1n } });
  context = reduceProjection(context, { type: "ACTIVITY.FRAME", frame: { operation: "upsert", epoch: 1n, sequence: 2n, agentId: "a", threadId: "t", label: "review", pending: true } });
  assert.match(selectActorUiSnapshot(context).footer, /Alpha:ready/);
  const reconnecting = reduceProjection(context, { type: "TRANSPORT.RECONNECTING" });
  assert.equal(selectActorUiSnapshot(reconnecting).footer, "actors reconnecting");
  assert.equal(selectActorUiSnapshot(reconnecting).rows[0].lifecycle, "reconnecting");
  assert.equal(selectActorUiSnapshot(reconnecting).rows[0].activity, undefined);
  assert.equal(selectActorUiSnapshot(reconnecting).rows[0].pending, false);
  const stale = reduceProjection(reconnecting, { type: "ROSTER.FRAME", frame: { operation: 3, epoch: 1n, sequence: 2n, agentId: "a", agent: { agentId: "a", displayName: "Alpha", hostedPiRuntime: { state: 3 } } } });
  assert.equal(selectActorUiSnapshot(stale).footer, "actors reconnecting");
  const subscribing = reduceProjection(context, { type: "TRANSPORT.SUBSCRIBING_ROSTER" });
  assert.equal(selectActorUiSnapshot(subscribing).footer, "actors subscribing");
  assert.equal(selectActorUiSnapshot(subscribing).rows[0].lifecycle, "subscribing");
  const reset = reduceProjection(subscribing, { type: "ROSTER.FRAME", frame: { operation: 2, epoch: 2n, sequence: 1n } });
  assert.equal(selectActorUiSnapshot(reset).footer, "actors none");
});

test("disconnected footer keeps connection state before pending and activity facts", () => {
  let context = reduceProjection(initialProjectionContext(), { type: "TASK.ADMITTED", pending: { key: "ask", requestId: "r", dedupeId: "d", chainId: "c", sourceMutationSequence: "1", target: "Code Reviewer", kind: "Ask", prompt: "question", hidden: true } });
  context = reduceProjection(context, { type: "ACTIVITY.FRAME", frame: { operation: "reset", epoch: 1n, sequence: 1n } });
  context = reduceProjection(context, { type: "ACTIVITY.FRAME", frame: { operation: "upsert", epoch: 1n, sequence: 2n, agentId: "actor", threadId: "t", label: "review" } });
  assert.match(selectActorUiSnapshot(context).footer, /^actors disconnected · 1 pending · 1 active/);
});

test("actor activity adapter naturalizes unknown future generated frames", () => {
  assert.deepEqual(adaptActorActivityFrame({ actorId: "actor-1", seq: 7, epoch: 2, op: "delete", requestId: "r", status: "CUSTOM_LABEL" }), { epoch: 2n, sequence: 7n, operation: "clear", agentId: "actor-1", threadId: "r", label: "CUSTOM_LABEL", pending: false });
  assert.deepEqual(adaptActorActivityFrame({ operation: 2, epoch: 3n, sequence: 4n, agentId: "actor-2", activity: { activityKey: "thread", label: "waiting_on_review", cleared: false } }), { epoch: 3n, sequence: 4n, operation: "upsert", agentId: "actor-2", threadId: "thread", label: "waiting_on_review", pending: true });
});

test("actor status overlay is width-safe, keyboard expandable, theme-invalidated, live-rendered, and sanitized", () => {
  const snapshots = [Object.freeze({ connection: "connected", footer: "actors Alpha:ready · 1 pending", rows: Object.freeze([Object.freeze({ agentId: "a", displayName: "Alpha", role: "review", lifecycle: "ready", activity: "Review", pending: true })]), overflow: 0, width: 80, themeRevision: 0, revision: 1 })];
  const calls = [];
  const theme = { fg: (name, text) => (calls.push(name), `\x1b[35m${text}\x1b[0m`), bg: (name, text) => (calls.push(name), `\x1b[7m${text}\x1b[0m`) };
  let closed = 0;
  const overlay = new ActorStatusOverlay(() => snapshots.at(-1), theme, () => closed++);
  for (const width of [20, 25, 49, 80]) {
    const lines = overlay.render(width);
    assert.ok(lines.every((line) => visibleWidth(line) <= width), `line exceeded ${width}: ${JSON.stringify(lines)}`);
  }
  overlay.handleInput("\r");
  assert.match(overlay.render(80).join("\n"), /role review|activity Review|request pending/);
  overlay.handleInput("\x1b[B");
  overlay.handleInput(" ");
  overlay.invalidate();
  assert.ok(calls.includes("accent"));
  snapshots.push(Object.freeze({ ...snapshots[0], footer: "actors Alpha:ready · 2 active", revision: 2 }));
  assert.match(overlay.render(80).join("\n"), /2 active/);
  overlay.handleInput("\x1b");
  assert.equal(closed, 1);
  assert.doesNotMatch(renderActorStatusFallback({ ...snapshots[0], footer: "bad\u001b[31m status", rows: [] }), /\u001b/);
});

test("actor status projection has no polling or control affordances", async () => {
  const source = await readFile(`${root}/index.ts`, "utf8");
  assert.match(source, /registerCommand\("actor-status"/);
  assert.doesNotMatch(source.match(/registerCommand\("actor-status"[\s\S]*?\}\);/)?.[0] ?? "", /setInterval\(|actor_list|actor-list/);
  const overlay = await readFile(`${root}/widgets/actor-status-overlay.ts`, "utf8");
  assert.match(source, /ctx\.mode!=="tui"/);
  assert.match(source, /payload\?\.case==="agentActivityFrame"/);
  assert.match(source, /activityFrames/);
  assert.match(source, /overlay:true/);
  assert.match(source, /dispose:\(\)=>projectionListeners\.delete/);
  assert.doesNotMatch(overlay, /stop|abort|shutdown|credential|principal|runtimeId|pid|tmux|prompt|answer|raw payload/i);
});

test("canonical completion keys prefer daemon keys and digest migration identity", () => {
  assert.equal(canonicalCompletionKey({ completionKey: "daemon-key" }), "daemon-key");
  const key = canonicalCompletionKey({ target: "target", source: "source", requestId: "r", dedupeId: "d", chainId: "c", sourceMutationSequence: 9n });
  assert.equal(key.length, 64);
  assert.equal(digestPresentation({ x: 1n }).length, 64);
});
