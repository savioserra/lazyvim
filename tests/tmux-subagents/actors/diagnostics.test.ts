import assert from "node:assert/strict";
import { mkdir, mkdtemp } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { DiagnosticJournal } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/adapters/diagnostic-journal.ts";
import { createDiagnosticsActor } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/actors/diagnostics.ts";

async function actorFixture(receipts: Array<{ decision: string }> = []) { const root = await mkdtemp(path.join(os.tmpdir(), "diagnostics-actor-")); const generationRoot = path.join(root, "generation"); await mkdir(generationRoot, { mode: 0o700 }); const actor = createDiagnosticsActor(new DiagnosticJournal(generationRoot, "generation"), (receipt) => receipts.push(receipt)); actor.start(); return actor; }
const command = (status: "start" | "success" | "failure", error?: unknown) => ({ type: "DIAGNOSTIC.COMMAND" as const, category: "command" as const, severity: error ? "error" as const : "info" as const, phase: "command", status, requestId: "request-1", receiptId: "receipt-1", ...(error ? { error } : {}) });

test("supervised diagnostics actor durably retrieves command failures and receipt ids", async () => {
  const actor = await actorFixture(); await actor.record(command("start")); await actor.record(command("failure", new Error("smoke failed"))); actor.setLatestErrorReceipt("receipt-1");
  const records = await actor.recent(10); assert.equal(records.length, 2); assert.match(records.at(-1)?.receiptId ?? "", /^receipt:[a-f0-9]{24}$/); assert.equal(records.at(-1)?.errorMessage, "local operation failed; use phase and receipt correlation"); assert.equal(actor.health().latestErrorReceipt, "receipt-1"); await actor.stop();
});

test("diagnostics observer opens its local circuit after bounded restart intensity", async () => {
  const receipts: Array<{ decision: string }> = []; const actor = await actorFixture(receipts); for (let attempt = 0; attempt < 4; attempt++) { await actor.crash(); if (attempt < 3) await new Promise((resolve) => setTimeout(resolve, [180, 300, 500][attempt])); }
  assert.equal(actor.childState(), "circuit-open"); assert.equal(receipts.at(-1)?.decision, "circuit-open"); await assert.rejects(actor.record(command("success")), /circuit-open/); await actor.stop();
});

test("diagnostics observer crash emits an OTP restart receipt and recovers without controlling authority", async () => {
  const receipts: Array<{ decision: string }> = []; const actor = await actorFixture(receipts); await actor.crash(); assert.equal(actor.childState(), "backoff"); assert.equal(receipts.at(-1)?.decision, "restart"); await new Promise((resolve) => setTimeout(resolve, 180)); assert.equal(actor.childState(), "running"); const record = await actor.record(command("success")); assert.equal(record.status, "success"); assert.equal(actor.health().state, "healthy"); await actor.stop();
});
