import assert from "node:assert/strict";
import test from "node:test";
import { callbackChildLogic, createSupervisorActor, durableSupervisorSnapshot, promiseChildLogic, type FailureReceipt, type RestartPolicy, type SupervisorStrategy } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/actors/supervisors/supervisor.ts";
import { createProductionSupervisorActor } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/actors/supervisors/production.ts";

async function until(predicate: () => boolean) { for (let attempt = 0; attempt < 200; attempt++) { if (predicate()) return; await new Promise((resolve) => setTimeout(resolve, 2)); } throw new Error("timed out"); }

function finiteScenario(strategy: SupervisorStrategy, restart: RestartPolicy = "permanent") {
  const starts: string[] = []; const completions = new Map<string, Array<() => void>>(); const receipts: FailureReceipt[] = []; const pending: any[] = [];
  const logic = promiseChildLogic(async (value) => {
    const input = value as { id: string }; starts.push(input.id); await new Promise<void>((resolve) => { const values = completions.get(input.id) ?? []; values.push(resolve); completions.set(input.id, values); });
  });
  const actor = createSupervisorActor({ id: `supervisor-${strategy}`, strategy, children: ["a", "b", "c"].map((id) => ({ id, restart, logic, input: { id } })),
    policy: { maxRestarts: 2, initialBackoffMs: 10, jitterRatio: 0 }, now: () => 100,
    schedule: (delay, event) => pending.push({ delay, event }), receipt: (value) => receipts.push(value) });
  actor.start(); actor.send({ type: "SUPERVISOR.START" });
  return { actor, starts, completions, receipts, pending };
}

for (const [strategy, expected] of [["one_for_one", ["b"]], ["one_for_all", ["a", "b", "c"]], ["rest_for_one", ["b", "c"]]] as const) {
  test(`OTP ${strategy} observes a real finite child completion and restarts owned effects`, async () => {
    const s = finiteScenario(strategy); await until(() => s.starts.length === 3);
    s.completions.get("b")![0]!(); await until(() => s.receipts.length === 1);
    assert.equal(s.receipts[0].abnormal, false); assert.deepEqual(s.receipts[0].affectedChildren, [...expected]); assert.equal(s.pending[0].delay, 10);
    s.actor.send(s.pending.shift().event); await until(() => s.starts.length === 3 + expected.length);
    assert.deepEqual(s.starts.slice(3).sort(), [...expected].sort()); s.actor.send({ type: "SUPERVISOR.STOP" });
  });
}

test("real finite children enforce permanent, transient, and temporary policies", async () => {
  for (const [restart, expected] of [["permanent", "restart"], ["transient", "ignore"], ["temporary", "ignore"]] as const) {
    const s = finiteScenario("one_for_one", restart); await until(() => s.starts.length === 3); s.completions.get("a")![0]!(); await until(() => s.receipts.length === 1);
    assert.equal(s.receipts[0].decision, expected); assert.equal(s.receipts[0].abnormal, false); s.actor.send({ type: "SUPERVISOR.STOP" });
  }
  const receipts: FailureReceipt[] = []; const pending: any[] = [];
  const failing = promiseChildLogic(async () => { throw new Error("real rejection"); });
  const actor = createSupervisorActor({ id: "transient", strategy: "one_for_one", children: [{ id: "child", restart: "transient", logic: failing }], receipt: (value) => receipts.push(value), schedule: (_delay, event) => pending.push(event) });
  actor.start(); actor.send({ type: "SUPERVISOR.START" }); await until(() => receipts.length === 1); assert.equal(receipts[0].decision, "restart"); assert.equal(receipts[0].abnormal, true); actor.send({ type: "SUPERVISOR.STOP" });
});

test("restart intensity opens the local circuit and durable snapshot excludes actor refs", () => {
  const receipts: FailureReceipt[] = []; const escalations: FailureReceipt[] = []; const pending: any[] = [];
  const actor = createSupervisorActor({ id: "circuit", strategy: "one_for_one", children: [{ id: "child", restart: "permanent", logic: callbackChildLogic(() => {}, () => {}) }], policy: { maxRestarts: 2, jitterRatio: 0 }, receipt: (value) => receipts.push(value), escalate: (value) => escalations.push(value), schedule: (_delay, event) => pending.push(event) });
  actor.start(); actor.send({ type: "SUPERVISOR.START" });
  for (let index = 0; index < 3; index++) { actor.send({ type: "CHILD.FAILED", childId: "child", reason: `boom-${index}`, abnormal: true, at: index }); if (pending.length) actor.send(pending.shift()); }
  assert.equal(receipts.at(-1)?.decision, "circuit-open"); assert.equal(escalations.length, 1);
  const durable = durableSupervisorSnapshot(actor.getSnapshot() as any); assert.equal(JSON.stringify(durable).includes("ref"), false); assert.equal(durable.children[0]?.state, "circuit-open"); actor.send({ type: "SUPERVISOR.STOP" });
});

test("production supervisor owns IPC, topology reconciliation, and projection publication effects", async () => {
  const effects: string[] = []; const receipts: FailureReceipt[] = [];
  const actor = createProductionSupervisorActor({ intervalMs: 5, startIpc: async () => { effects.push("ipc:start"); }, stopIpc: async () => { effects.push("ipc:stop"); }, reconcile: async () => { effects.push("reconcile"); }, publishProjection: async () => { effects.push("publish"); }, receipt: (receipt) => receipts.push(receipt) });
  actor.start(); actor.send({ type: "PROJECTION.PUBLISH", projection: {} as any }); await actor.executeTopology(async () => { effects.push("topology:open"); return "pane"; }); await until(() => effects.includes("ipc:start") && effects.includes("reconcile") && effects.includes("publish")); actor.stop(); await until(() => effects.includes("ipc:stop"));
  assert.ok(effects.includes("topology:open")); assert.deepEqual(receipts, []);
});

function production(topologyTimeoutMs = 250) {
  return createProductionSupervisorActor({ intervalMs: 10_000, topologyTimeoutMs, startIpc: async () => {}, stopIpc: async () => {}, reconcile: async () => {}, publishProjection: async () => {} });
}
async function settles<T>(promise: Promise<T>): Promise<T> {
  return Promise.race([promise, new Promise<T>((_resolve, reject) => setTimeout(() => reject(new Error("promise remained unresolved")), 500))]);
}

test("topology request accepted before child failure rejects and backoff rejects new delivery immediately", async () => {
  const actor = production(); actor.start();
  const accepted = actor.executeTopology(() => new Promise<never>(() => {}));
  await new Promise((resolve) => setTimeout(resolve, 5)); actor.send({ type: "CHILD.FAILED", childId: "topology-reconciliation", reason: "boundary crashed", abnormal: true });
  await assert.rejects(settles(accepted), /topology child (exited|restart)/);
  assert.equal(actor.childState("topology-reconciliation"), "backoff");
  await assert.rejects(settles(actor.executeTopology(async () => "unreachable")), /backoff/); actor.stop();
});

test("topology circuit-open and supervisor shutdown reject rather than dropping requests", async () => {
  const actor = production(); actor.start();
  for (let attempt = 0; attempt < 4; attempt++) actor.send({ type: "CHILD.FAILED", childId: "topology-reconciliation", reason: `failure-${attempt}`, abnormal: true, at: attempt });
  assert.equal(actor.childState("topology-reconciliation"), "circuit-open");
  await assert.rejects(settles(actor.executeTopology(async () => "unreachable")), /circuit-open/); actor.stop();
  await assert.rejects(settles(actor.executeTopology(async () => "unreachable")), /stopped/);
});

test("topology operation timeout settles an accepted request", async () => {
  const actor = production(20); actor.start();
  await assert.rejects(settles(actor.executeTopology(() => new Promise<never>(() => {}))), /timed out after 20ms/); actor.stop();
});

test("adopted renderer observers are temporary and never relaunched", async () => {
  let starts = 0; const receipts: FailureReceipt[] = [];
  const actor = createProductionSupervisorActor({ intervalMs: 10_000, startIpc: async () => {}, stopIpc: async () => {}, reconcile: async () => {}, publishProjection: async () => {}, receipt: (receipt) => receipts.push(receipt) });
  actor.start(); const delivery = actor.addRenderer({ childId: "renderer:adopted", restart: "temporary", run: async () => { starts += 1; throw new Error("foreign pane disappeared"); } });
  assert.equal(delivery.delivered, true); await until(() => receipts.some((receipt) => receipt.childId === "renderer:adopted")); await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(starts, 1); assert.equal(receipts.find((receipt) => receipt.childId === "renderer:adopted")?.decision, "ignore"); actor.stop();
});

test("supervisor child delivery reports missing, stopped, and backoff states", () => {
  const actor = createSupervisorActor({ id: "delivery", strategy: "one_for_one", children: [{ id: "child", restart: "permanent", logic: callbackChildLogic(() => {}, () => {}) }], schedule: () => {} });
  actor.start(); assert.equal(actor.sendChild("child", {}).state, "supervisor-stopped"); actor.send({ type: "SUPERVISOR.START" });
  assert.equal(actor.sendChild("missing", {}).state, "missing"); actor.send({ type: "CHILD.FAILED", childId: "child", reason: "failed", abnormal: true });
  assert.equal(actor.sendChild("child", {}).state, "backoff"); actor.send({ type: "CHILD.REMOVE", childId: "child" }); actor.send({ type: "SUPERVISOR.RESTART_DUE", childIds: ["child"] });
  assert.equal(actor.sendChild("child", {}).state, "missing", "a removed backoff child must not restart from a stale timer"); actor.send({ type: "SUPERVISOR.STOP" }); assert.equal(actor.sendChild("child", {}).state, "supervisor-stopped");
});
