import { createHash, randomUUID } from "node:crypto";
import { constants, lstat, mkdir, open, realpath, rename, unlink } from "node:fs/promises";
import path from "node:path";
import type { DiagnosticEvent, DiagnosticRecord } from "../protocol/diagnostic-events.ts";

export const MAX_DIAGNOSTIC_LINE_BYTES = 2048;
export const MAX_DIAGNOSTIC_JOURNAL_BYTES = 128 * 1024;
export const MAX_DIAGNOSTIC_QUERY_COUNT = 50;
const ALLOWED_METADATA = new Set(["action", "method", "decision", "restartAttempt", "source", "state", "count", "created", "abnormal"]);
const ALLOWED_PHASES = new Set(["unknown", "bootstrap-ready", "system-initialize", "generation-initialize", "system-ready", "system-start", "generation-dispose", "prior-generation-reap", "xstate-actor", "command", "root-supervisor-receipt", "production-supervisor-receipt", "production-supervisor-escalation", "topology-operation", "ipc-server", "ipc-parse", "ipc-authentication", "ipc-rate-limit", "ipc-timeout", "ipc-socket", "renderer-authenticated", "renderer-disconnected", "adopted-renderer-monitor", "created-renderer-lifecycle", "created-renderer-authenticated", "runtime-attestation", "authority-snapshot-precondition", "isolated-root", "isolated-tmux", "foreign-tuple-capture", "ipc-start", "renderer-launch-claim-auth-render", "renderer-sigkill-observed", "renderer-supervised-restart", "control-acknowledgement", "stale-generation-rejection", "detach", "created-pane-absent", "foreign-tuple-unchanged", "authority-unchanged", "cleanup", "rpc-ping", "rpc-status", "rpc-steer", "rpc-interrupt", "rpc-stop", "rpc-resume"]);
const ALLOWED_CATEGORIES = new Set(["lifecycle", "command", "smoke", "rpc", "renderer", "ipc", "tmux", "topology", "supervisor", "generation"]);
const ALLOWED_SEVERITIES = new Set(["debug", "info", "warning", "error"]);
const ALLOWED_STATUSES = new Set(["start", "success", "failure", "checkpoint", "exit", "restart", "circuit-open"]);
const METADATA_VALUES: Record<string, Set<string>> = {
  action: new Set(["doctor", "diagnostics", "status", "reload", "smoke", "refresh", "focus", "close", "prepare", "open", "unknown"]),
  method: new Set(["ping", "status", "steer", "interrupt", "stop", "resume", "unknown"]),
  decision: new Set(["ignore", "restart", "circuit-open", "escalate", "unknown"]),
  source: new Set(["extension", "renderer", "production-reconciliation", "unknown"]),
  state: new Set(["active", "complete", "failed", "stopped", "rejected", "running", "removed", "prior", "unknown"]),
};

function uid(): number | undefined { return typeof process.getuid === "function" ? process.getuid() : undefined; }
async function assertOwned(item: string, directory: boolean): Promise<void> {
  const metadata = await lstat(item);
  if (metadata.isSymbolicLink() || (directory ? !metadata.isDirectory() : !metadata.isFile())) throw new Error(`diagnostic ${item} must be an owned ${directory ? "directory" : "regular file"}`);
  if (uid() !== undefined && metadata.uid !== uid()) throw new Error(`diagnostic ${item} has foreign ownership`);
  const expected = directory ? 0o700 : 0o600;
  if ((metadata.mode & 0o777) !== expected) throw new Error(`diagnostic ${item} must have mode ${expected.toString(8)}`);
}
async function syncDirectory(item: string): Promise<void> { const handle = await open(item, constants.O_RDONLY); try { await handle.sync(); } finally { await handle.close(); } }
async function ensureDirectory(item: string): Promise<void> {
  await mkdir(item, { recursive: true, mode: 0o700 });
  await assertOwned(item, true); await syncDirectory(item);
}
function safeText(value: unknown, maximum: number): string | undefined {
  if (typeof value !== "string" || !value) return undefined;
  let text = value.replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, " ").replace(/\s+/g, " ").trim();
  text = text
    .replace(/\b(nonce|token|secret|password|credential|authorization)\s*[:=]\s*[^ ]+/gi, "$1=[REDACTED]")
    .replace(/\b(?:Bearer|Basic)\s+[A-Za-z0-9+/_=.-]+/gi, "[REDACTED_CREDENTIAL]")
    .replace(/\b[A-Za-z0-9_-]{24,}\b/g, "[REDACTED]")
    .replace(/(?:\/[^ ]+){2,}/g, "[PATH]")
    .replace(/(?:[A-Za-z]:\\|\\\\)[^ ]+/g, "[PATH]");
  return text.slice(0, maximum) || undefined;
}
function safeId(domain: "request" | "receipt" | "actor" | "binding", value: unknown): string | undefined {
  if (typeof value !== "string" || !value) return undefined;
  return `${domain}:${createHash("sha256").update(`tmux-subagents-diagnostic:v1:${domain}\0${value}`).digest("hex").slice(0, 24)}`;
}
function safeError(error: unknown): { errorCode?: string; errorMessage?: string } {
  if (error === undefined) return {};
  const input = error instanceof Error ? error : new Error("untyped failure"); const errno = (input as NodeJS.ErrnoException).code;
  if (typeof errno === "string" && /^(?:EACCES|EEXIST|EINVAL|EIO|ENOENT|ENOTDIR|EPERM|ETIMEDOUT)$/.test(errno)) return { errorCode: errno, errorMessage: "filesystem or runtime operation failed" };
  const message = input.message.toLowerCase();
  if (/timeout|timed out/.test(message)) return { errorCode: "TIMEOUT", errorMessage: "bounded operation timed out" };
  if (/authentic|credential|nonce|token/.test(message)) return { errorCode: "AUTHENTICATION", errorMessage: "authentication or credential validation failed" };
  if (/owner|permission|mode |symlink|path escape|canonical/.test(message)) return { errorCode: "OWNERSHIP", errorMessage: "ownership or path validation failed" };
  if (/incompatible|version|protocol/.test(message)) return { errorCode: "INCOMPATIBLE", errorMessage: "compatibility validation failed" };
  if (/circuit|backoff|supervisor|restart/.test(message)) return { errorCode: "SUPERVISION", errorMessage: "supervised boundary failed" };
  if (/visible current-session run|precondition/.test(message)) return { errorCode: "PRECONDITION", errorMessage: "required observable precondition was not met" };
  if (/unavailable|not ready|disabled|missing/.test(message)) return { errorCode: "UNAVAILABLE", errorMessage: "required local capability was unavailable" };
  return { errorCode: "OPERATION_FAILED", errorMessage: "local operation failed; use phase and receipt correlation" };
}
function safeMetadata(input: Record<string, unknown> | undefined): Record<string, string | number | boolean> | undefined {
  if (!input) return undefined;
  const output: Record<string, string | number | boolean> = {};
  for (const [key, value] of Object.entries(input).slice(0, 12)) {
    if (!ALLOWED_METADATA.has(key)) continue;
    if (typeof value === "boolean" || (typeof value === "number" && Number.isFinite(value))) output[key] = value;
    else { const text = typeof value === "string" && METADATA_VALUES[key]?.has(value) ? value : "unknown"; output[key] = text; }
  }
  return Object.keys(output).length ? output : undefined;
}

export class DiagnosticJournal {
  readonly root: string;
  readonly currentPath: string;
  readonly rotatedPath: string;
  readonly lockPath: string;
  readonly generation: string;
  private sequence = 0;
  private queue: Promise<unknown> = Promise.resolve();
  private locked = false;
  private initializing?: Promise<void>;

  constructor(generationRoot: string, generation: string) {
    const resolvedGeneration = path.resolve(generationRoot);
    this.root = path.join(resolvedGeneration, "diagnostics");
    if (!this.root.startsWith(`${resolvedGeneration}${path.sep}`)) throw new Error("diagnostic journal escapes generation root");
    this.currentPath = path.join(this.root, "events.ndjson");
    this.rotatedPath = path.join(this.root, "events.1.ndjson");
    this.lockPath = path.join(this.root, "writer.lock");
    this.generation = generation;
  }

  private async readRecords(file: string): Promise<DiagnosticRecord[]> {
    try {
      await assertOwned(file, false); const noFollow = (constants as Record<string, number>).O_NOFOLLOW ?? 0; const handle = await open(file, constants.O_RDONLY | noFollow);
      try { const metadata = await handle.stat(); if (metadata.size > MAX_DIAGNOSTIC_JOURNAL_BYTES) throw new Error("diagnostic journal exceeds its byte limit"); const contents = await handle.readFile("utf8"); const records: DiagnosticRecord[] = [];
        for (const line of contents.split("\n")) if (line) { if (Buffer.byteLength(line) > MAX_DIAGNOSTIC_LINE_BYTES) throw new Error("diagnostic journal contains an oversized line"); const parsed = JSON.parse(line) as DiagnosticRecord; if (parsed.schemaVersion !== 1 || parsed.generation !== this.generation || !Number.isSafeInteger(parsed.sequence)) throw new Error("diagnostic journal record is incompatible"); records.push(parsed); } return records;
      } finally { await handle.close(); }
    } catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return []; throw error; }
  }

  private async acquire(): Promise<void> {
    await ensureDirectory(this.root); if (await realpath(this.root) !== this.root) throw new Error("diagnostic journal root is not canonical");
    for (const file of [this.currentPath, this.rotatedPath]) { try { await assertOwned(file, false); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; } }
    const noFollow = (constants as Record<string, number>).O_NOFOLLOW ?? 0; const handle = await open(this.lockPath, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | noFollow, 0o600);
    try {
      try { await handle.writeFile(`${JSON.stringify({ schemaVersion: 1, pid: process.pid, instance: randomUUID() })}\n`, "utf8"); await handle.sync(); } finally { await handle.close(); }
      await assertOwned(this.lockPath, false); await syncDirectory(this.root); const records = [...await this.readRecords(this.rotatedPath), ...await this.readRecords(this.currentPath)]; this.sequence = records.reduce((maximum, record) => Math.max(maximum, record.sequence), 0); this.locked = true;
    } catch (error) { await handle.close().catch(() => {}); await unlink(this.lockPath).catch(() => {}); await syncDirectory(this.root).catch(() => {}); throw error; }
  }

  private async initialize(): Promise<void> {
    if (this.locked) return; this.initializing ??= this.acquire();
    try { await this.initializing; } finally { this.initializing = undefined; }
  }

  private serialize(event: DiagnosticEvent): DiagnosticRecord {
    if (!ALLOWED_CATEGORIES.has(event.category) || !ALLOWED_SEVERITIES.has(event.severity) || !ALLOWED_STATUSES.has(event.status) || !ALLOWED_PHASES.has(event.phase)) throw new Error("invalid diagnostic enum");
    const record: DiagnosticRecord = {
      schemaVersion: 1,
      sequence: ++this.sequence,
      timestamp: Date.now(),
      generation: this.generation,
      category: event.category,
      severity: event.severity,
      phase: event.phase,
      status: event.status,
      ...(safeId("request", event.requestId) ? { requestId: safeId("request", event.requestId) } : {}),
      ...(safeId("receipt", event.receiptId) ? { receiptId: safeId("receipt", event.receiptId) } : {}),
      ...(safeId("actor", event.actorId) ? { actorId: safeId("actor", event.actorId) } : {}),
      ...(safeId("binding", event.bindingId) ? { bindingId: safeId("binding", event.bindingId) } : {}),
      ...safeError(event.error),
      ...(safeMetadata(event.metadata) ? { metadata: safeMetadata(event.metadata) } : {}),
    };
    let line = `${JSON.stringify(record)}\n`;
    if (Buffer.byteLength(line) > MAX_DIAGNOSTIC_LINE_BYTES) {
      record.errorMessage = record.errorMessage?.slice(0, 120);
      delete record.metadata;
      line = `${JSON.stringify(record)}\n`;
    }
    if (Buffer.byteLength(line) > MAX_DIAGNOSTIC_LINE_BYTES) throw new Error("diagnostic record exceeds its line limit");
    return record;
  }

  private async appendNow(event: DiagnosticEvent): Promise<DiagnosticRecord> {
    await this.initialize();
    const record = this.serialize(event); const line = `${JSON.stringify(record)}\n`; const noFollow = (constants as Record<string, number>).O_NOFOLLOW ?? 0;
    let currentSize = 0; let created = false;
    try { currentSize = (await lstat(this.currentPath)).size; } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; created = true; }
    if (currentSize + Buffer.byteLength(line) > MAX_DIAGNOSTIC_JOURNAL_BYTES) {
      try { await assertOwned(this.rotatedPath, false); await unlink(this.rotatedPath); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
      try { await assertOwned(this.currentPath, false); await rename(this.currentPath, this.rotatedPath); created = true; await syncDirectory(this.root); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
    }
    const handle = await open(this.currentPath, constants.O_APPEND | constants.O_CREAT | constants.O_WRONLY | noFollow, 0o600);
    try {
      const metadata = await handle.stat();
      if (!metadata.isFile() || (uid() !== undefined && metadata.uid !== uid()) || (metadata.mode & 0o777) !== 0o600) throw new Error("diagnostic journal changed during secure append");
      await handle.writeFile(line, "utf8"); await handle.sync();
    } finally { await handle.close(); }
    await assertOwned(this.currentPath, false); if (created) await syncDirectory(this.root);
    return record;
  }

  append(event: DiagnosticEvent): Promise<DiagnosticRecord> {
    const operation = this.queue.then(() => this.appendNow(event));
    this.queue = operation.catch(() => undefined);
    return operation;
  }

  async recent(count: number): Promise<DiagnosticRecord[]> {
    await this.queue; await this.initialize(); const bounded = Math.max(1, Math.min(MAX_DIAGNOSTIC_QUERY_COUNT, Math.floor(count || 10))); const records = [...await this.readRecords(this.rotatedPath), ...await this.readRecords(this.currentPath)];
    return records.sort((a, b) => a.sequence - b.sequence).slice(-bounded);
  }

  async close(): Promise<void> {
    await this.queue; if (!this.locked) return; await assertOwned(this.lockPath, false); await unlink(this.lockPath); await syncDirectory(this.root); this.locked = false;
  }
}
