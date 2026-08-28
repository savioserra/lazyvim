import assert from "node:assert/strict";
import { chmod, lstat, mkdir, mkdtemp, readFile, symlink, unlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { DiagnosticJournal, MAX_DIAGNOSTIC_JOURNAL_BYTES, MAX_DIAGNOSTIC_LINE_BYTES, MAX_DIAGNOSTIC_QUERY_COUNT } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/adapters/diagnostic-journal.ts";

async function fixture() { const root = await mkdtemp(path.join(os.tmpdir(), "diagnostic-journal-")); const generationRoot = path.join(root, "generation"); await mkdir(generationRoot, { mode: 0o700 }); return { root, generationRoot, journal: new DiagnosticJournal(generationRoot, "generation") }; }
const event = (phase: string, error?: unknown) => ({ type: "DIAGNOSTIC.COMMAND" as const, category: "command" as const, severity: error ? "error" as const : "info" as const, phase: phase === "evil-phase" ? phase : "command", status: error ? "failure" as const : "success" as const, ...(error ? { error } : {}) });

test("diagnostic journal serializes concurrent appenders and bounds retrieval", async () => {
  const { journal } = await fixture(); await Promise.all(Array.from({ length: 80 }, (_, index) => journal.append(event(`phase-${index}`))));
  const records = await journal.recent(5000); assert.equal(records.length, MAX_DIAGNOSTIC_QUERY_COUNT); assert.equal(new Set(records.map((record) => record.sequence)).size, records.length); assert.ok(records.every((record, index) => index === 0 || record.sequence > records[index - 1].sequence));
  assert.equal((await lstat(journal.root)).mode & 0o777, 0o700); assert.equal((await lstat(journal.currentPath)).mode & 0o777, 0o600);
});

test("diagnostic journal redacts secrets, paths, arbitrary metadata, and bounds lines", async () => {
  const { journal } = await fixture(); const secret = "A".repeat(64);
  await journal.append({ ...event("command"), error: new Error(`Bearer abc Basic Zm9v nonce=short /home/user/private/file C:\\Users\\name\\secret \\\\server\\share\\secret prompt output RPC environment`), metadata: { action: "smoke", method: "Bearer abc", state: "C:\\secret", decision: "prompt-output", source: "RPC_SECRET", prompt: secret, environment: secret, nested: { token: secret }, count: 2 } });
  const contents = await readFile(journal.currentPath, "utf8"); for (const forbidden of [secret, "Bearer abc", "Basic Zm9v", "nonce=short", "/home/user/private/file", "C:\\\\Users", "server\\\\share", "prompt", "output", "RPC", "environment"]) assert.ok(!contents.includes(forbidden), `journal leaked ${forbidden}`); assert.ok(!contents.includes("nested"));
  assert.ok(Buffer.byteLength(contents.split("\n")[0]) <= MAX_DIAGNOSTIC_LINE_BYTES); const [record] = await journal.recent(1); assert.equal(record.phase, "command"); assert.deepEqual(record.metadata, { action: "smoke", method: "unknown", state: "unknown", decision: "unknown", source: "unknown", count: 2 });
});

test("diagnostic journal rejects each invalid runtime enum independently", async () => {
  const { journal } = await fixture();
  for (const invalid of [
    { category: "evil" }, { severity: "fatal" }, { status: "owned" }, { phase: "evil-phase" },
  ]) await assert.rejects(journal.append({ ...event("command"), ...invalid } as any), /invalid diagnostic enum/);
});

test("diagnostic journal domain-separates and sanitizes every correlation field independently", async () => {
  const { journal } = await fixture(); const secret = "Bearer SAME-CREDENTIAL"; const fields = ["requestId", "receiptId", "actorId", "bindingId"] as const;
  for (const field of fields) { const record = await journal.append({ ...event("command"), [field]: secret }); assert.match(record[field] ?? "", new RegExp(`^${field.replace("Id", "")}:[a-f0-9]{24}$`)); }
  const separated = await journal.append({ ...event("command"), requestId: secret, receiptId: secret, actorId: secret, bindingId: secret }); assert.equal(new Set([separated.requestId, separated.receiptId, separated.actorId, separated.bindingId]).size, 4);
  assert.doesNotMatch(await readFile(journal.currentPath, "utf8"), /SAME-CREDENTIAL|Bearer/);
});

test("diagnostic journal rotates within its byte cap", async () => {
  const { journal } = await fixture(); for (let index = 0; index < 1500; index++) await journal.append(event(`rotate-${index}`, new Error("x ".repeat(225))));
  assert.ok((await lstat(journal.currentPath)).size <= MAX_DIAGNOSTIC_JOURNAL_BYTES); assert.ok((await lstat(journal.rotatedPath)).size <= MAX_DIAGNOSTIC_JOURNAL_BYTES); const recent = await journal.recent(10); assert.equal(recent.length, 10); await journal.close(); const reopened = new DiagnosticJournal(path.dirname(journal.root), "generation"); const next = await reopened.append(event("after-rotation")); assert.ok(next.sequence > recent.at(-1)!.sequence); await reopened.close();
});

test("diagnostic journal enforces one writer and resumes monotonic sequence after a clean reopen", async () => {
  const { generationRoot, journal } = await fixture(); const first = await journal.append(event("first")); const contender = new DiagnosticJournal(generationRoot, "generation"); await assert.rejects(contender.append(event("contender")), /EEXIST|writer/); await journal.close(); const reopened = new DiagnosticJournal(generationRoot, "generation"); const second = await reopened.append(event("second")); assert.ok(second.sequence > first.sequence); await reopened.close();
});

test("corrupt acquisition removes its exact lock and permits a repaired retry", async () => {
  const { generationRoot, journal } = await fixture(); await journal.append(event("valid")); await journal.close(); await writeFile(journal.currentPath, "{corrupt}\n", { mode: 0o600 }); const reopened = new DiagnosticJournal(generationRoot, "generation"); await assert.rejects(reopened.append(event("blocked")), /JSON/); await assert.rejects(lstat(reopened.lockPath), /ENOENT/); await unlink(reopened.currentPath); const record = await reopened.append(event("repaired")); assert.equal(record.sequence, 1); await reopened.close();
});

test("diagnostic journal rejects symlink and unsafe mode swaps", async () => {
  const first = await fixture(); const elsewhere = await mkdtemp(path.join(os.tmpdir(), "diagnostic-elsewhere-")); await symlink(elsewhere, first.journal.root); await assert.rejects(first.journal.append(event("symlink")), /owned directory/);
  const second = await fixture(); await second.journal.append(event("mode")); await chmod(second.journal.currentPath, 0o666); await assert.rejects(second.journal.append(event("unsafe")), /mode 600|changed during secure append/);
});
