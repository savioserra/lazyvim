import test from "node:test";
import assert from "node:assert/strict";
import { createActor } from "../../home/dot_pi/private_agent/extensions/actor-client/node_modules/xstate/dist/xstate.cjs.js";
import { visibleWidth } from "../../home/dot_pi/private_agent/extensions/actor-client/node_modules/@earendil-works/pi-tui/dist/index.js";
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

test("client semantic families remain distinct and runtime frozen", async () => {
  const types = await import("../../home/dot_pi/private_agent/extensions/actor-client/projections/types.ts");
  assert.deepEqual(types.CLIENT_SEMANTIC_FAMILIES, ["Tell", "Ask", "UserTurn", "SelfContinuation", "Waiting", "Blocked", "Completion", "PresentationAck", "Introspection"]);
  assert.equal(Object.isFrozen(types.CLIENT_SEMANTIC_FAMILIES), true);
  assert.throws(() => types.CLIENT_SEMANTIC_FAMILIES.push("Tell"), /object is not extensible|read only|Cannot add property/);
  assert.deepEqual(types.CLIENT_SEMANTIC_FAMILIES, ["Tell", "Ask", "UserTurn", "SelfContinuation", "Waiting", "Blocked", "Completion", "PresentationAck", "Introspection"]);
});

test("pre-snapshot admission and reincarnation cannot bootstrap actor authority", () => {
  let context = reduceProjection(initialProjectionContext(), { type: "USER_TURN.ADMISSION.REQUESTED", proposedTurnId: "misrouted", actorEpoch: "epoch-wrong", baseTranscriptSeq: 0, idempotencyKey: "idem-wrong" });
  assert.equal(context.actorEpoch, undefined);
  assert.equal(context.turnAdmission.actorEpoch, undefined);
  context = reduceProjection(context, { type: "USER_TURN.ADMISSION.DECISION", proposedTurnId: "misrouted", actorEpoch: "epoch-wrong", decision: "admit", admissionToken: "bad-token" });
  assert.equal(context.actorEpoch, undefined);
  assert.equal(context.turnAdmission.state, "admission_pending");
  context = reduceProjection(context, { type: "ACTOR.REINCARNATION", newActorEpoch: "epoch-attacker", recovery: "lossless", executorRecovery: "same_generation_valid", currentExecutor: { ref: { actorEpoch: "epoch-attacker", executorId: "exec", executorGeneration: "gen" }, state: "running", lifecycleSeq: 1 } });
  assert.equal(context.actorEpoch, undefined);
  assert.equal(context.replayAuthority, false);
  assert.equal(context.executor.current, undefined);
  context = reduceProjection(context, { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-real", transcriptSeq: 1, eventSeq: 1 });
  assert.equal(context.actorEpoch, "epoch-real");
  assert.equal(context.turnAdmission.state, "admission_required");
});

test("unsolicited admission decision cannot admit a turn", () => {
  let context = reduceProjection(initialProjectionContext(), { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-a", transcriptSeq: 1, eventSeq: 1 });
  context = reduceProjection(context, { type: "USER_TURN.ADMISSION.DECISION", proposedTurnId: "turn-1", actorEpoch: "epoch-a", decision: "admit", admissionToken: "token" });
  assert.equal(context.turnAdmission.state, "admission_required");
  assert.equal(context.turnAdmission.admissionToken, undefined);
});

test("user turn submit validates full admission tuple and clears non-rendered token", () => {
  let context = reduceProjection(initialProjectionContext(), { type: "CLIENT.DRAFT.SET", draft: "ship this?" });
  context = reduceProjection(context, { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-a", transcriptSeq: 10, eventSeq: 1 });
  context = reduceProjection(context, { type: "USER_TURN.ADMISSION.REQUESTED", proposedTurnId: "turn-1", actorEpoch: "epoch-a", baseTranscriptSeq: 10, idempotencyKey: "idem-admit-1" });
  context = reduceProjection(context, { type: "USER_TURN.ADMISSION.DECISION", proposedTurnId: "turn-1", actorEpoch: "epoch-a", decision: "admit", admissionToken: "token-secret-1", reason: "ok secret=abc" });
  assert.equal(context.turnAdmission.reason.includes("secret=abc"), false);
  for (const bad of [
    { proposedTurnId: "other", turnId: "turn-1", actorEpoch: "epoch-a", admissionToken: "token-secret-1", idempotencyKey: "idem-admit-1" },
    { proposedTurnId: "turn-1", turnId: "other", actorEpoch: "epoch-a", admissionToken: "token-secret-1", idempotencyKey: "idem-admit-1" },
    { proposedTurnId: "turn-1", turnId: "turn-1", actorEpoch: "epoch-b", admissionToken: "token-secret-1", idempotencyKey: "idem-admit-1" },
    { proposedTurnId: "turn-1", turnId: "turn-1", actorEpoch: "epoch-a", admissionToken: "wrong", idempotencyKey: "idem-admit-1" },
    { proposedTurnId: "turn-1", turnId: "turn-1", actorEpoch: "epoch-a", admissionToken: "token-secret-1", idempotencyKey: "other" },
  ]) {
    const attempted = reduceProjection(context, { type: "USER_TURN.SUBMITTED", ...bad });
    assert.equal(attempted.snapshot.inputState, "admitted");
  }
  context = reduceProjection(context, { type: "USER_TURN.SUBMITTED", proposedTurnId: "turn-1", turnId: "turn-1", actorEpoch: "epoch-a", admissionToken: "token-secret-1", idempotencyKey: "idem-admit-1" });
  assert.equal(context.snapshot.inputState, "executing");
  assert.equal(context.turnAdmission.admissionToken, undefined);
  assert.equal(JSON.stringify(context.snapshot).includes("token-secret-1"), false);
  context = reduceProjection(context, { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-a", transcriptSeq: 11, eventSeq: 22, availableContinuations: [], availableIntrospections: [] });
  assert.equal(context.draft, "ship this?");
});

test("defer or reject decisions carrying tokens clear submit authority", () => {
  let context = reduceProjection(initialProjectionContext(), { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-a", transcriptSeq: 1, eventSeq: 1 });
  context = reduceProjection(context, { type: "USER_TURN.ADMISSION.REQUESTED", proposedTurnId: "turn-1", actorEpoch: "epoch-a", baseTranscriptSeq: 1, idempotencyKey: "idem-1" });
  context = reduceProjection(context, { type: "USER_TURN.ADMISSION.DECISION", proposedTurnId: "turn-1", actorEpoch: "epoch-a", decision: "defer", admissionToken: "token-forbidden", reason: "blocked token=abc" });
  assert.equal(context.turnAdmission.admissionToken, undefined);
  assert.equal(context.turnAdmission.reason.includes("token=abc"), false);
  let attempted = reduceProjection(context, { type: "USER_TURN.SUBMITTED", proposedTurnId: "turn-1", turnId: "turn-1", actorEpoch: "epoch-a", admissionToken: "token-forbidden", idempotencyKey: "idem-1" });
  assert.equal(attempted.snapshot.inputState, "blocked");
  context = reduceProjection(context, { type: "USER_TURN.ADMISSION.REQUESTED", proposedTurnId: "turn-2", actorEpoch: "epoch-a", baseTranscriptSeq: 1, idempotencyKey: "idem-2" });
  context = reduceProjection(context, { type: "USER_TURN.ADMISSION.DECISION", proposedTurnId: "turn-2", actorEpoch: "epoch-a", decision: "reject", admissionToken: "token-forbidden-2", reason: "no secret=abc" });
  assert.equal(context.turnAdmission.admissionToken, undefined);
  attempted = reduceProjection(context, { type: "USER_TURN.SUBMITTED", proposedTurnId: "turn-2", turnId: "turn-2", actorEpoch: "epoch-a", admissionToken: "token-forbidden-2", idempotencyKey: "idem-2" });
  assert.equal(attempted.snapshot.inputState, "admission_required");
});

test("stale admission request is rejected after actor authority exists", () => {
  let context = reduceProjection(initialProjectionContext(), { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-a", transcriptSeq: 1, eventSeq: 1 });
  context = reduceProjection(context, { type: "USER_TURN.ADMISSION.REQUESTED", proposedTurnId: "turn-b", actorEpoch: "epoch-b", baseTranscriptSeq: 1, idempotencyKey: "idem-b" });
  assert.equal(context.actorEpoch, "epoch-a");
  assert.equal(context.turnAdmission.state, "admission_required");
  context = reduceProjection(context, { type: "USER_TURN.ADMISSION.REQUESTED", proposedTurnId: "turn-a", actorEpoch: "epoch-a", baseTranscriptSeq: 1, idempotencyKey: "idem-a" });
  assert.equal(context.turnAdmission.state, "admission_pending");
  let attempted = reduceProjection(context, { type: "USER_TURN.ADMISSION.REQUESTED", proposedTurnId: "turn-a2", actorEpoch: "epoch-a", baseTranscriptSeq: 1, idempotencyKey: "idem-a2" });
  assert.equal(attempted.turnAdmission.proposedTurnId, "turn-a");
  context = reduceProjection(context, { type: "USER_TURN.ADMISSION.DECISION", proposedTurnId: "turn-a", actorEpoch: "epoch-a", decision: "admit", admissionToken: "token-a" });
  attempted = reduceProjection(context, { type: "USER_TURN.ADMISSION.REQUESTED", proposedTurnId: "turn-a2", actorEpoch: "epoch-a", baseTranscriptSeq: 1, idempotencyKey: "idem-a2" });
  assert.equal(attempted.turnAdmission.proposedTurnId, "turn-a");
  context = reduceProjection(context, { type: "USER_TURN.SUBMITTED", proposedTurnId: "turn-a", turnId: "turn-a", actorEpoch: "epoch-a", admissionToken: "token-a", idempotencyKey: "idem-a" });
  attempted = reduceProjection(context, { type: "USER_TURN.ADMISSION.REQUESTED", proposedTurnId: "turn-a2", actorEpoch: "epoch-a", baseTranscriptSeq: 1, idempotencyKey: "idem-a2" });
  assert.equal(attempted.turnAdmission.state, "executing");
  context = reduceProjection(context, { type: "ACTOR.REINCARNATION", oldActorEpoch: "epoch-a", newActorEpoch: "epoch-b", recovery: "state_lost", executorRecovery: "executor_absent" });
  context = reduceProjection(context, { type: "USER_TURN.ADMISSION.REQUESTED", proposedTurnId: "turn-b", actorEpoch: "epoch-b", baseTranscriptSeq: 1, idempotencyKey: "idem-b" });
  assert.equal(context.turnAdmission.state, "state_lost");
});

test("executor lifecycle cannot establish authority before snapshot", () => {
  const ref = { actorEpoch: "epoch-a", executorId: "exec", executorGeneration: "gen-a" };
  let context = reduceProjection(initialProjectionContext(), { type: "EXECUTOR.LIFECYCLE", executor: ref, state: "running", lifecycleSeq: 1 });
  assert.equal(context.actorEpoch, undefined);
  assert.equal(context.executor.current, undefined);
  context = reduceProjection(context, { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-a", transcriptSeq: 1, eventSeq: 1 });
  context = reduceProjection(context, { type: "EXECUTOR.LIFECYCLE", executor: ref, state: "running", lifecycleSeq: 1 });
  assert.equal(context.executor.current, undefined);
});

test("stale reincarnation cannot change epoch or replay authority", () => {
  let context = reduceProjection(initialProjectionContext(), { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-a", transcriptSeq: 1, eventSeq: 1 });
  context = reduceProjection(context, { type: "ACTOR.REINCARNATION", oldActorEpoch: "epoch-x", newActorEpoch: "epoch-b", recovery: "lossless", executorRecovery: "same_generation_valid" });
  assert.equal(context.actorEpoch, "epoch-a");
  assert.equal(context.replayAuthority, true);
  context = reduceProjection(context, { type: "ACTOR.REINCARNATION", newActorEpoch: "epoch-b", recovery: "lossless", executorRecovery: "same_generation_valid" });
  assert.equal(context.actorEpoch, "epoch-a");
});

test("executor controls and events are fenced by actor epoch and executor generation", () => {
  const refA = { actorEpoch: "epoch-a", executorId: "exec", executorGeneration: "gen-a" };
  const refB = { actorEpoch: "epoch-a", executorId: "exec", executorGeneration: "gen-b" };
  let context = reduceProjection(initialProjectionContext(), { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-a", transcriptSeq: 1, eventSeq: 1, executor: { ref: refA, state: "running", lifecycleSeq: 1 } });
  context = reduceProjection(context, { type: "EXECUTOR.COMMAND.REQUESTED", executor: refB, command: "request_stop", idempotencyKey: "stop-stale" });
  assert.equal(context.executor.pendingCommands.size, 0);
  context = reduceProjection(context, { type: "EXECUTOR.COMMAND.REQUESTED", executor: refA, command: "request_stop", idempotencyKey: "stop-current" });
  assert.equal(context.executor.pendingCommands.size, 1);
  context = reduceProjection(context, { type: "EXECUTOR.COMMAND.RESULT", executor: refA, status: "accepted", idempotencyKey: "stop-current" });
  assert.equal(context.executor.pendingCommands.size, 0);
  context = reduceProjection(context, { type: "EXECUTOR.LIFECYCLE", executor: refB, state: "stopped", lifecycleSeq: 2 });
  assert.equal(context.executor.state, "running");
  context = reduceProjection(context, { type: "EXECUTOR.LIFECYCLE", executor: { ...refA, actorEpoch: "epoch-old" }, state: "failed", lifecycleSeq: 3 });
  assert.equal(context.executor.state, "running");
  context = reduceProjection(context, { type: "EXECUTOR.LIFECYCLE", executor: refA, state: "stopping", lifecycleSeq: 2 });
  assert.equal(context.executor.state, "stopping");
  context = reduceProjection(context, { type: "EXECUTOR.LIFECYCLE", executor: refA, state: "failed", lifecycleSeq: 2 });
  assert.equal(context.executor.state, "stopping");
});

test("snapshot rejects stale epoch seq and transcript regressions", () => {
  const ref = { actorEpoch: "epoch-a", executorId: "exec-secret", executorGeneration: "gen-secret" };
  let context = reduceProjection(initialProjectionContext(), { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-a", transcriptSeq: 5, eventSeq: 5, executor: { ref, state: "running", lifecycleSeq: 1 } });
  assert.equal(context.executor.state, "running");
  assert.equal(context.snapshot.executorLine, "executor running");
  assert.equal(JSON.stringify(context.snapshot).includes("exec-secret"), false);
  assert.equal(JSON.stringify(context.snapshot).includes("gen-secret"), false);
  let attempted = reduceProjection(context, { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-b", transcriptSeq: 6, eventSeq: 6, executor: { ref: { ...ref, actorEpoch: "epoch-b" }, state: "failed", lifecycleSeq: 1 } });
  assert.equal(attempted.actorEpoch, "epoch-a");
  attempted = reduceProjection(context, { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-a", transcriptSeq: 6, eventSeq: 5, executor: { ref, state: "failed", lifecycleSeq: 2 } });
  assert.equal(attempted.executor.state, "running");
  attempted = reduceProjection(context, { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-a", transcriptSeq: 4, eventSeq: 6, executor: { ref, state: "failed", lifecycleSeq: 2 } });
  assert.equal(attempted.transcriptSeq, 5);
});

test("snapshot replaces affordances and old executor commands while preserving draft", () => {
  const refA = { actorEpoch: "epoch-a", executorId: "exec", executorGeneration: "gen-a" };
  const refB = { actorEpoch: "epoch-a", executorId: "exec", executorGeneration: "gen-b" };
  let context = reduceProjection(initialProjectionContext(), { type: "CLIENT.DRAFT.SET", draft: "local unsent text" });
  context = reduceProjection(context, { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-a", transcriptSeq: 1, eventSeq: 1, executor: { ref: refA, state: "running", lifecycleSeq: 1 }, availableContinuations: [{ continuationId: "cont-old", turnId: "t", label: "Continue", mode: "suggested", actorEpoch: "epoch-a", eventSeq: 1 }], availableIntrospections: [{ introspectionId: "intro-old", scope: "last_turn", privacyNotice: "server scoped", actorEpoch: "epoch-a", eventSeq: 1 }] });
  context = reduceProjection(context, { type: "EXECUTOR.COMMAND.REQUESTED", executor: refA, command: "request_abort", idempotencyKey: "abort-a" });
  context = reduceProjection(context, { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-a", transcriptSeq: 2, eventSeq: 2, executor: { ref: refB, state: "running", lifecycleSeq: 1 }, availableContinuations: [{ continuationId: "cont-new", turnId: "t2", label: "Continue", mode: "recommended", actorEpoch: "epoch-a", eventSeq: 2 }], availableIntrospections: [] });
  assert.equal(context.draft, "local unsent text");
  assert.equal(context.executor.pendingCommands.size, 0);
  assert.equal(context.affordances.continuations.has("cont-old"), false);
  assert.equal(context.affordances.continuations.has("cont-new"), true);
  assert.equal(context.affordances.introspections.size, 0);
});

test("presentation ack binds actor tuple, sanitizes requirement, dedupes replay, and is payload-free", () => {
  let context = reduceProjection(initialProjectionContext(), { type: "TRANSPORT.CONNECTED" });
  context = reduceProjection(context, { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-a", transcriptSeq: 2, eventSeq: 1 });
  context = reduceProjection(context, { type: "PRESENTATION.RENDERED", presentationId: "p1", turnId: "t", transcriptSeq: 2, actorEpoch: "epoch-a", clientSessionId: "s", renderedAt: "2026-01-01T00:00:00Z", visibleRegion: { firstSeq: 1, lastSeq: 2 } });
  assert.equal(context.presentationAckOutbox.length, 0);
  context = reduceProjection(context, { type: "PRESENTATION.REQUIRED", presentationId: "p1", turnId: "t", transcriptSeq: 2, actorEpoch: "epoch-a", eventSeq: 2, requirement: "assistant_output_visible token=abc" });
  assert.match(context.snapshot.presentationAckLine, /waiting/);
  assert.equal([...context.pendingPresentation.values()][0].requirement.includes("token=abc"), false);
  const collision = reduceProjection(context, { type: "PRESENTATION.REQUIRED", presentationId: "p1", turnId: "other", transcriptSeq: 2, actorEpoch: "epoch-a", eventSeq: 3, requirement: "tool_request_visible" });
  assert.equal(collision.pendingPresentation.size, 1);
  context = reduceProjection(context, { type: "PRESENTATION.RENDERED", presentationId: "p1", turnId: "other", transcriptSeq: 2, actorEpoch: "epoch-a", clientSessionId: "s", renderedAt: "2026-01-01T00:00:00Z" });
  assert.equal(context.presentationAckOutbox.length, 0);
  context = reduceProjection(context, { type: "PRESENTATION.RENDERED", presentationId: "p1", turnId: "t", transcriptSeq: 2, actorEpoch: "epoch-a", clientSessionId: "s", renderedAt: "2026-01-01T00:00:00Z", visibleRegion: { firstSeq: 1, lastSeq: 2 } });
  context = reduceProjection(context, { type: "PRESENTATION.RENDERED", presentationId: "p1", turnId: "t", transcriptSeq: 2, actorEpoch: "epoch-a", clientSessionId: "s", renderedAt: "2026-01-01T00:00:01Z", visibleRegion: { firstSeq: 1, lastSeq: 2 } });
  assert.equal(context.pendingPresentation.size, 0);
  assert.equal(context.presentationAckOutbox.length, 1);
  context = reduceProjection(context, { type: "PRESENTATION.REQUIRED", presentationId: "p1", turnId: "t", transcriptSeq: 2, actorEpoch: "epoch-a", eventSeq: 3, requirement: "assistant_output_visible" });
  context = reduceProjection(context, { type: "PRESENTATION.RENDERED", presentationId: "p1", turnId: "t", transcriptSeq: 2, actorEpoch: "epoch-a", clientSessionId: "s", renderedAt: "2026-01-01T00:00:02Z" });
  assert.equal(context.pendingPresentation.size, 0);
  assert.equal(context.presentationAckOutbox.length, 1);
  assert.deepEqual(context.presentationAckOutbox[0], { type: "client.presentation.ack", presentationId: "p1", turnId: "t", transcriptSeq: 2, actorEpoch: "epoch-a", clientSessionId: "s", renderedAt: "2026-01-01T00:00:00Z", visibleRegion: { firstSeq: 1, lastSeq: 2 } });
  assert.equal(JSON.stringify(context.presentationAckOutbox).includes("assistant_output_visible"), false);
  assert.equal(JSON.stringify(context.presentationAckOutbox).includes("token=abc"), false);
});

test("snapshot replay cannot resurrect acknowledged presentation tuple", () => {
  let context = reduceProjection(initialProjectionContext(), { type: "TRANSPORT.CONNECTED" });
  context = reduceProjection(context, { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-a", transcriptSeq: 2, eventSeq: 1 });
  context = reduceProjection(context, { type: "PRESENTATION.REQUIRED", presentationId: "p-acked", turnId: "t", transcriptSeq: 2, actorEpoch: "epoch-a", eventSeq: 2, requirement: "assistant_output_visible" });
  context = reduceProjection(context, { type: "PRESENTATION.RENDERED", presentationId: "p-acked", turnId: "t", transcriptSeq: 2, actorEpoch: "epoch-a", clientSessionId: "s", renderedAt: "2026-01-01T00:00:00Z" });
  assert.equal(context.presentationAckOutbox.length, 1);
  context = reduceProjection(context, { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-a", transcriptSeq: 2, eventSeq: 3, pendingPresentation: [{ presentationId: "p-acked", turnId: "t", transcriptSeq: 2, actorEpoch: "epoch-a", requirement: "assistant_output_visible" }] });
  assert.equal(context.pendingPresentation.size, 0);
  context = reduceProjection(context, { type: "PRESENTATION.RENDERED", presentationId: "p-acked", turnId: "t", transcriptSeq: 2, actorEpoch: "epoch-a", clientSessionId: "s", renderedAt: "2026-01-01T00:00:01Z" });
  assert.equal(context.presentationAckOutbox.length, 1);
});

test("continuation and introspection affordances require actor authority and sanitize text", () => {
  let context = initialProjectionContext();
  context = reduceProjection(context, { type: "CONTINUATION.AVAILABLE", continuationId: "c0", turnId: "t0", label: "Continue token=abc", mode: "required_ack", actorEpoch: "epoch-a", eventSeq: 1 });
  assert.equal(context.affordances.continuations.size, 0);
  context = reduceProjection(context, { type: "TRANSPORT.CONNECTED" });
  context = reduceProjection(context, { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-a", transcriptSeq: 1, eventSeq: 1 });
  context = reduceProjection(context, { type: "CONTINUATION.AVAILABLE", continuationId: "stale", turnId: "t1", label: "Old", mode: "suggested", actorEpoch: "epoch-a", eventSeq: 1 });
  context = reduceProjection(context, { type: "CONTINUATION.AVAILABLE", continuationId: "wrong", turnId: "t1", label: "Wrong", mode: "suggested", actorEpoch: "epoch-b", eventSeq: 2 });
  assert.equal(context.affordances.continuations.size, 0);
  context = reduceProjection(context, { type: "CONTINUATION.AVAILABLE", continuationId: "c1", turnId: "t1", label: "Continue token=abc", mode: "required_ack", actorEpoch: "epoch-a", eventSeq: 2 });
  context = reduceProjection(context, { type: "INTROSPECTION.AVAILABLE", introspectionId: "i1", scope: "executor_state", privacyNotice: "actor state only secret=abc", actorEpoch: "epoch-a", eventSeq: 3 });
  assert.equal(context.affordances.continuations.get("c1").label.includes("token=abc"), false);
  assert.equal(context.affordances.introspections.get("i1").privacyNotice.includes("secret=abc"), false);
  assert.match(context.snapshot.continuationLine, /continuation/);
  assert.match(context.snapshot.introspectionLine, /introspection/);
});

test("reincarnation replay state clears stale affordances and gates input", () => {
  const ref = { actorEpoch: "epoch-a", executorId: "exec", executorGeneration: "gen-a" };
  let context = reduceProjection(initialProjectionContext(), { type: "CLIENT.DRAFT.SET", draft: "keep me" });
  context = reduceProjection(context, { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-a", transcriptSeq: 1, eventSeq: 1, executor: { ref, state: "running", lifecycleSeq: 1 }, availableContinuations: [{ continuationId: "c", turnId: "t", label: "Continue", mode: "suggested", actorEpoch: "epoch-a", eventSeq: 1 }] });
  context = reduceProjection(context, { type: "ACTOR.REINCARNATION", oldActorEpoch: "epoch-a", newActorEpoch: "epoch-b", recovery: "state_lost", executorRecovery: "executor_absent" });
  assert.equal(context.draft, "keep me");
  assert.equal(context.snapshot.inputState, "state_lost");
  assert.equal(context.executor.current, undefined);
  assert.equal(context.affordances.continuations.size, 0);
  context = reduceProjection(context, { type: "CONTINUATION.AVAILABLE", continuationId: "after-loss", turnId: "t", label: "Continue", mode: "suggested", actorEpoch: "epoch-b", eventSeq: 1 });
  context = reduceProjection(context, { type: "INTROSPECTION.AVAILABLE", introspectionId: "after-loss", scope: "last_turn", privacyNotice: "state", actorEpoch: "epoch-b", eventSeq: 2 });
  context = reduceProjection(context, { type: "PRESENTATION.REQUIRED", presentationId: "after-loss", turnId: "t", transcriptSeq: 1, actorEpoch: "epoch-b", eventSeq: 3, requirement: "assistant_output_visible" });
  assert.equal(context.affordances.continuations.size, 0);
  assert.equal(context.affordances.introspections.size, 0);
  assert.equal(context.pendingPresentation.size, 0);
  context = reduceProjection(context, { type: "TRANSPORT.CONNECTED" });
  context = reduceProjection(context, { type: "ACTOR.SNAPSHOT", actorEpoch: "epoch-b", transcriptSeq: 1, eventSeq: 3 });
  context = reduceProjection(context, { type: "CONTINUATION.AVAILABLE", continuationId: "after-snapshot", turnId: "t", label: "Continue", mode: "suggested", actorEpoch: "epoch-b", eventSeq: 4 });
  assert.equal(context.affordances.continuations.has("after-snapshot"), true);
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
