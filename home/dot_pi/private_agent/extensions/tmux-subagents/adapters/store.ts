import { execFile } from "node:child_process";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { constants, link, lstat, mkdir, open, readFile, readdir, realpath, rename, rm, unlink } from "node:fs/promises";
import { promisify } from "node:util";
import path from "node:path";
import { MAX_PROJECTION_BYTES, TICKET_SCHEMA_VERSION } from "../domain/constants.ts";
import { renderProjectionText, type Projection } from "../domain/projection.ts";
import type { PaneIdentity } from "../domain/types.ts";
export type { PaneIdentity } from "../domain/types.ts";

export interface ViewBinding {
  schemaVersion: 1;
  bindingId: string;
  generation: string;
  ownerPiSessionId: string;
  runId: string;
  childId?: string;
  created: boolean;
  projectionPath: string;
  pane: PaneIdentity;
  createdAt: number;
}

export interface ViewTicket {
  schemaVersion: 1;
  ticketId: string;
  nonce: string;
  generation: string;
  ownerPiSessionId: string;
  runId: string;
  childId?: string;
  created: boolean;
  expectedPane?: PaneIdentity;
  issuedAt: number;
  expiresAt: number;
  projectionPath: string;
  claimPath: string;
  rendererSocketPath?: string;
  nodePath?: string;
  rendererPath?: string;
}

export interface PaneClaim {
  schemaVersion: 1;
  ticketId: string;
  nonce: string;
  tmux: string;
  paneId: string;
  claimedAt: number;
}

function validIdentity(value: string, label: string): string {
  if (!/^[A-Za-z0-9._:@+-]{1,160}$/.test(value) || value.includes("..")) throw new Error(`${label} is invalid`);
  return value;
}

function object(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be an object`);
  return value as Record<string, unknown>;
}

function currentUid(): number | undefined {
  return typeof process.getuid === "function" ? process.getuid() : undefined;
}
export type ProcessStartIdentity = { status: "known"; identity: string } | { status: "indeterminate"; reason: string };
export interface PrivateViewStoreOptions {
  processIdentity?: (pid: number) => Promise<ProcessStartIdentity>;
  beforeLeaseTransition?: (transition: "release" | "remove-owned" | "remove-stale") => Promise<void>;
}
export function darwinProcessStartIdentity(output: string): string | undefined { const started = output.trim(); return started ? `darwin:${started}` : undefined; }
const execFileAsync = promisify(execFile);
async function defaultProcessStartIdentity(pid: number): Promise<ProcessStartIdentity> {
  try {
    if (process.platform === "darwin") {
      const result = await execFileAsync("ps", ["-o", "lstart=", "-p", String(pid)], { encoding: "utf8", timeout: 1000 });
      const identity = darwinProcessStartIdentity(result.stdout); return identity ? { status: "known", identity } : { status: "indeterminate", reason: "ps returned no process start time" };
    }
    if (process.platform === "linux") {
      const stat = await readFile(`/proc/${pid}/stat`, "utf8"); const close = stat.lastIndexOf(")"); const fields = stat.slice(close + 2).trim().split(/\s+/); const identity = fields[19];
      return identity ? { status: "known", identity: `linux:${identity}` } : { status: "indeterminate", reason: "procfs omitted process start time" };
    }
    return { status: "indeterminate", reason: `process start identity is unsupported on ${process.platform}` };
  } catch (error) { return { status: "indeterminate", reason: `process start identity lookup failed: ${(error as NodeJS.ErrnoException).code ?? "unknown"}` }; }
}

async function assertOwned(file: string, directory: boolean): Promise<void> {
  const metadata = await lstat(file);
  if (metadata.isSymbolicLink() || (directory ? !metadata.isDirectory() : !metadata.isFile())) {
    throw new Error(`${file} must be an owned ${directory ? "directory" : "regular file"}, not a symlink`);
  }
  const uid = currentUid();
  if (uid !== undefined && metadata.uid !== uid) throw new Error(`${file} has foreign ownership`);
  const expected = directory ? 0o700 : 0o600;
  const mode = metadata.mode & 0o777;
  if (mode !== expected) throw new Error(`${file} must have mode ${expected.toString(8)}, got ${mode.toString(8)}`);
}

async function ensureDirectory(directory: string): Promise<void> {
  try {
    await mkdir(directory, { mode: 0o700 });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
  }
  await assertOwned(directory, true);
}

async function secureRead(file: string, maxBytes: number): Promise<string> {
  await assertOwned(file, false);
  const noFollow = (constants as Record<string, number>).O_NOFOLLOW ?? 0;
  const handle = await open(file, constants.O_RDONLY | noFollow);
  try {
    const metadata = await handle.stat();
    const uid = currentUid();
    if (!metadata.isFile() || (uid !== undefined && metadata.uid !== uid) || (metadata.mode & 0o777) !== 0o600) {
      throw new Error(`${file} changed during secure open`);
    }
    if (metadata.size > maxBytes) throw new Error(`${file} exceeds its byte limit`);
    return await handle.readFile("utf8");
  } finally {
    await handle.close();
  }
}

export async function atomicWrite(file: string, contents: string, maxBytes: number): Promise<void> {
  if (Buffer.byteLength(contents, "utf8") > maxBytes) throw new Error(`refusing to write oversized private record ${file}`);
  await assertOwned(path.dirname(file), true);
  try {
    await assertOwned(file, false);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  const temporary = path.join(path.dirname(file), `.${path.basename(file)}.${randomUUID()}.tmp`);
  const noFollow = (constants as Record<string, number>).O_NOFOLLOW ?? 0;
  const handle = await open(temporary, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | noFollow, 0o600);
  try {
    await handle.writeFile(contents, "utf8");
    await handle.sync();
  } finally {
    await handle.close();
  }
  try {
    await rename(temporary, file);
    await assertOwned(file, false);
  } catch (error) {
    await unlink(temporary).catch(() => {});
    throw error;
  }
}

function sessionKey(sessionId: string): string {
  return createHash("sha256").update(sessionId).digest("hex").slice(0, 12);
}

function parseTicket(input: unknown, label: string): ViewTicket {
  const ticket = object(input, label);
  if (
    ticket.schemaVersion !== TICKET_SCHEMA_VERSION ||
    typeof ticket.ticketId !== "string" ||
    typeof ticket.nonce !== "string" ||
    typeof ticket.generation !== "string" ||
    typeof ticket.ownerPiSessionId !== "string" ||
    typeof ticket.runId !== "string" ||
    typeof ticket.created !== "boolean" ||
    typeof ticket.issuedAt !== "number" ||
    typeof ticket.expiresAt !== "number" ||
    typeof ticket.projectionPath !== "string" ||
    typeof ticket.claimPath !== "string"
  ) throw new Error(`${label} schema is incompatible`);
  return ticket as unknown as ViewTicket;
}

export class PrivateViewStore {
  readonly baseRoot: string;
  readonly sessionRoot: string;
  readonly generationsRoot: string;
  readonly generationRoot: string;
  readonly ticketsRoot: string;
  readonly projectionsRoot: string;
  readonly bindingsRoot: string;
  readonly receiptsRoot: string;
  readonly socketsRoot: string;
  readonly leasePath: string;
  readonly ownerPiSessionId: string;
  readonly generation: string;
  readonly leaseToken: string;
  private leaseStartIdentity?: string;
  private readonly options: PrivateViewStoreOptions;

  constructor(root: string, ownerPiSessionId: string, generation: string, options: PrivateViewStoreOptions = {}) {
    this.ownerPiSessionId = validIdentity(ownerPiSessionId, "Pi session id"); this.options = options;
    this.generation = validIdentity(generation, "generation"); this.leaseToken = randomBytes(24).toString("base64url");
    this.baseRoot = path.resolve(root);
    this.sessionRoot = path.join(this.baseRoot, sessionKey(this.ownerPiSessionId));
    this.generationsRoot = path.join(this.sessionRoot, "generations");
    this.generationRoot = path.join(this.generationsRoot, this.generation);
    this.ticketsRoot = path.join(this.generationRoot, "tickets");
    this.projectionsRoot = path.join(this.generationRoot, "projections");
    this.bindingsRoot = path.join(this.generationRoot, "bindings");
    this.receiptsRoot = path.join(this.generationRoot, "supervisor-receipts");
    this.socketsRoot = path.join(this.generationRoot, "sockets");
    this.leasePath = path.join(this.generationRoot, "owner-lease.json");
  }

  private confined(file: string): string {
    const resolved = path.resolve(file);
    if (resolved !== this.generationRoot && !resolved.startsWith(`${this.generationRoot}${path.sep}`)) {
      throw new Error(`private record escapes generation root: ${file}`);
    }
    return resolved;
  }

  async initialize(): Promise<void> {
    for (const directory of [this.baseRoot, this.sessionRoot, this.generationsRoot, this.generationRoot]) await ensureDirectory(directory);
    const canonical = await realpath(this.generationRoot); if (canonical !== this.generationRoot) throw new Error("private generation root is not canonical");
    if (this.leaseStartIdentity === undefined) {
      const identity = await (this.options.processIdentity ?? defaultProcessStartIdentity)(process.pid);
      if (identity.status === "known") this.leaseStartIdentity = identity.identity;
    }
    try {
      const lease = object(JSON.parse(await secureRead(this.leasePath, 1024)), "generation lease");
      if (lease.schemaVersion !== 1 || lease.generation !== this.generation || lease.pid !== process.pid || lease.ownerToken !== this.leaseToken || lease.processStartIdentity !== (this.leaseStartIdentity ?? null)) throw new Error("generation lease belongs to another live owner");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      await atomicWrite(this.leasePath, `${JSON.stringify({ schemaVersion: 1, generation: this.generation, pid: process.pid, ownerToken: this.leaseToken, processStartIdentity: this.leaseStartIdentity ?? null, startedAt: Date.now() })}\n`, 1024);
    }
    for (const directory of [this.ticketsRoot, this.projectionsRoot, this.bindingsRoot, this.receiptsRoot, this.socketsRoot]) await ensureDirectory(directory);
  }

  async reapLease(): Promise<{ status: "stale"; ownerToken: string; processStartIdentity: string | null } | { status: "active" | "indeterminate"; reason: string }> {
    try {
      const lease = object(JSON.parse(await secureRead(this.leasePath, 1024)), "generation lease");
      if (lease.schemaVersion !== 1 || lease.generation !== this.generation || typeof lease.pid !== "number" || !Number.isSafeInteger(lease.pid) || lease.pid <= 0 || typeof lease.ownerToken !== "string" || !/^[A-Za-z0-9_-]{32}$/.test(lease.ownerToken) || (lease.processStartIdentity !== null && typeof lease.processStartIdentity !== "string")) return { status: "indeterminate", reason: "generation lease is incompatible" };
      if (lease.released === true) return { ownerToken: lease.ownerToken, processStartIdentity: lease.processStartIdentity as string | null, status: "stale" };
      let alive = true; try { process.kill(lease.pid, 0); } catch (error) { if ((error as NodeJS.ErrnoException).code === "ESRCH") alive = false; else return { status: "indeterminate", reason: "generation lease liveness is unknown" }; }
      if (!alive) return { ownerToken: lease.ownerToken, processStartIdentity: lease.processStartIdentity as string | null, status: "stale" };
      const currentStart = await (this.options.processIdentity ?? defaultProcessStartIdentity)(lease.pid); if (currentStart.status !== "known" || typeof lease.processStartIdentity !== "string") return { status: "indeterminate", reason: currentStart.status === "indeterminate" ? currentStart.reason : "lease process start identity is unavailable" };
      if (currentStart.identity === lease.processStartIdentity) return { status: "active", reason: "generation owner is still active" };
      return { ownerToken: lease.ownerToken, processStartIdentity: lease.processStartIdentity, status: "stale" };
    } catch { return { status: "indeterminate", reason: "generation lease could not be securely read" }; }
  }

  private ownsLease(lease: Record<string, unknown>): boolean { return lease.schemaVersion === 1 && lease.generation === this.generation && lease.pid === process.pid && lease.ownerToken === this.leaseToken && lease.processStartIdentity === (this.leaseStartIdentity ?? null); }
  private async assertCurrentOwnerIdentity(): Promise<void> {
    if (!this.leaseStartIdentity) throw new Error("generation ownership is indeterminate without process start identity"); const current = await (this.options.processIdentity ?? defaultProcessStartIdentity)(process.pid);
    if (current.status !== "known" || current.identity !== this.leaseStartIdentity) throw new Error("generation process start identity changed before destructive transition");
  }

  async releaseLease(): Promise<void> {
    if (!this.leaseStartIdentity) throw new Error("generation lease release is indeterminate without process start identity");
    const before = object(JSON.parse(await secureRead(this.leasePath, 1024)), "generation lease"); if (!this.ownsLease(before)) throw new Error("generation lease ownership changed before release");
    await this.options.beforeLeaseTransition?.("release"); await this.assertCurrentOwnerIdentity();
    const claim = path.join(this.generationRoot, `.owner-lease.release.${randomUUID()}`); await rename(this.leasePath, claim);
    let claimed: Record<string, unknown>;
    try { claimed = object(JSON.parse(await secureRead(claim, 1024)), "generation lease"); }
    catch (error) { try { await link(claim, this.leasePath); await unlink(claim); } catch (restore) { throw new AggregateError([error, restore], "generation lease read failed and could not be restored without replacement"); } throw error; }
    if (!this.ownsLease(claimed)) {
      try { await link(claim, this.leasePath); await unlink(claim); } catch (restore) { throw new AggregateError([restore], "generation lease changed during release and could not be restored without replacing another owner"); }
      throw new Error("generation lease ownership changed during release");
    }
    await this.assertCurrentOwnerIdentity(); const released = path.join(this.generationRoot, `.owner-lease.released.${randomUUID()}`);
    await atomicWrite(released, `${JSON.stringify({ ...claimed, released: true })}\n`, 1024);
    try { await link(released, this.leasePath); }
    catch (error) { throw new AggregateError([error], "generation lease was replaced during release"); }
    finally { await unlink(released).catch((error: NodeJS.ErrnoException) => { if (error.code !== "ENOENT") throw error; }); await unlink(claim).catch((error: NodeJS.ErrnoException) => { if (error.code !== "ENOENT") throw error; }); }
  }

  async removeStaleGeneration(ownerToken: string, startIdentity: string | null): Promise<void> {
    const before = await this.reapLease(); if (before.status !== "stale" || before.ownerToken !== ownerToken || before.processStartIdentity !== startIdentity) throw new Error("generation lease changed or is not proven stale");
    await this.options.beforeLeaseTransition?.("remove-stale"); await this.removeGenerationAfterRename(async (movedLease) => {
      const lease = object(JSON.parse(await secureRead(movedLease, 1024)), "generation lease");
      if (lease.ownerToken !== ownerToken || lease.processStartIdentity !== startIdentity) throw new Error("generation lease changed during stale removal");
      if (lease.released !== true) {
        let alive = true; try { process.kill(lease.pid as number, 0); } catch (error) { if ((error as NodeJS.ErrnoException).code === "ESRCH") alive = false; else throw error; }
        if (alive) { const identity = await (this.options.processIdentity ?? defaultProcessStartIdentity)(lease.pid as number); if (identity.status !== "known" || identity.identity === lease.processStartIdentity) throw new Error("generation owner is active or indeterminate during stale removal"); }
      }
    });
  }

  async createTicket(input: { ticketId?: string; runId: string; childId?: string; created: boolean; expectedPane?: PaneIdentity; rendererSocketPath?: string; nodePath?: string; rendererPath?: string; ttlMs: number; now?: number }): Promise<ViewTicket> {
    await this.initialize();
    const now = input.now ?? Date.now();
    if (input.created !== (input.expectedPane !== undefined)) throw new Error("created pane tickets require one exact expected pane identity");
    const ticketId = input.ticketId ? validIdentity(input.ticketId, "ticket id") : randomUUID();
    const projectionPath = this.confined(path.join(this.projectionsRoot, `${ticketId}.txt`));
    const claimPath = this.confined(path.join(this.ticketsRoot, `${ticketId}.claim.json`));
    const ticket: ViewTicket = {
      schemaVersion: TICKET_SCHEMA_VERSION,
      ticketId,
      nonce: randomBytes(32).toString("base64url"),
      generation: this.generation,
      ownerPiSessionId: this.ownerPiSessionId,
      runId: validIdentity(input.runId, "run id"),
      ...(input.childId ? { childId: validIdentity(input.childId, "child id") } : {}),
      created: input.created,
      ...(input.expectedPane ? { expectedPane: input.expectedPane } : {}),
      issuedAt: now,
      expiresAt: now + input.ttlMs,
      projectionPath,
      claimPath,
      ...(input.rendererSocketPath ? { rendererSocketPath: path.resolve(input.rendererSocketPath) } : {}),
      ...(input.nodePath ? { nodePath: path.resolve(input.nodePath) } : {}),
      ...(input.rendererPath ? { rendererPath: path.resolve(input.rendererPath) } : {}),
    };
    await atomicWrite(this.ticketPath(ticketId), `${JSON.stringify(ticket)}\n`, 8192);
    await atomicWrite(projectionPath, "tmux subagents\nWaiting for the extension projection…\n", MAX_PROJECTION_BYTES);
    return ticket;
  }

  ticketPath(ticketId: string): string {
    return this.confined(path.join(this.ticketsRoot, `${validIdentity(ticketId, "ticket id")}.json`));
  }

  async readTicket(ticketId: string, now = Date.now(), allowExpired = false): Promise<ViewTicket> {
    const ticket = parseTicket(JSON.parse(await secureRead(this.ticketPath(ticketId), 8192)), "ticket");
    if (ticket.ticketId !== ticketId) throw new Error("ticket identity is incompatible");
    if (ticket.generation !== this.generation || ticket.ownerPiSessionId !== this.ownerPiSessionId) throw new Error("ticket belongs to another generation");
    if (this.confined(ticket.projectionPath) !== ticket.projectionPath || this.confined(ticket.claimPath) !== ticket.claimPath) throw new Error("ticket paths escape their generation");
    if (ticket.rendererSocketPath && (path.dirname(ticket.rendererSocketPath) !== this.socketsRoot || path.basename(ticket.rendererSocketPath) !== "renderer.sock")) {
      throw new Error("ticket renderer socket escapes its private generation");
    }
    if ((ticket.nodePath !== undefined && !path.isAbsolute(ticket.nodePath)) || (ticket.rendererPath !== undefined && !path.isAbsolute(ticket.rendererPath))) throw new Error("ticket runtime paths must be absolute");
    if (!allowExpired && ticket.expiresAt < now) throw new Error("ticket expired");
    return ticket;
  }

  async consumeClaim(ticketId: string, now = Date.now()): Promise<{ ticket: ViewTicket; claim: PaneClaim }> {
    const ticket = await this.readTicket(ticketId, now);
    const input = object(JSON.parse(await secureRead(ticket.claimPath, 8192)), "pane claim");
    if (
      input.schemaVersion !== TICKET_SCHEMA_VERSION || input.ticketId !== ticket.ticketId || input.nonce !== ticket.nonce ||
      typeof input.tmux !== "string" || typeof input.paneId !== "string" || !/^%[0-9]+$/.test(input.paneId) ||
      typeof input.claimedAt !== "number" || input.claimedAt < ticket.issuedAt || input.claimedAt > now + 30_000
    ) throw new Error("pane claim does not match its one-use ticket");
    const consumed = this.confined(path.join(this.ticketsRoot, `${ticketId}.consumed.${randomUUID()}`));
    await rename(this.ticketPath(ticketId), consumed);
    await unlink(ticket.claimPath).catch(() => {});
    return { ticket, claim: input as unknown as PaneClaim };
  }

  async writeProjection(ticket: ViewTicket, projection: Projection): Promise<void> {
    if (ticket.generation !== this.generation) throw new Error("cannot write foreign projection");
    await this.writeProjectionPath(ticket.projectionPath, projection);
  }

  async writeProjectionPath(projectionPath: string, projection: Projection): Promise<void> {
    const confined = this.confined(projectionPath);
    if (path.dirname(confined) !== this.projectionsRoot) throw new Error("cannot write foreign projection");
    await atomicWrite(confined, renderProjectionText(projection), MAX_PROJECTION_BYTES);
  }

  async closeProjection(projectionPath: string): Promise<void> {
    const confined = this.confined(projectionPath);
    if (path.dirname(confined) !== this.projectionsRoot) throw new Error("refusing to close a foreign projection");
    await atomicWrite(confined, "TMUX_SUBAGENTS_VIEW_CLOSED\nView closed; the managed run continues.\n", MAX_PROJECTION_BYTES);
  }

  async writeBinding(binding: ViewBinding): Promise<void> {
    if (binding.generation !== this.generation || binding.ownerPiSessionId !== this.ownerPiSessionId || this.confined(binding.projectionPath) !== binding.projectionPath) {
      throw new Error("cannot persist a foreign binding");
    }
    await atomicWrite(this.confined(path.join(this.bindingsRoot, `${validIdentity(binding.bindingId, "binding id")}.json`)), `${JSON.stringify(binding)}\n`, 16 * 1024);
  }

  async writeSupervisorReceipt(receipt: { supervisorId: string; childId: string; decision: string; reason: string; at: number; restartAttempt: number }): Promise<void> {
    const decisions = new Set(["ignore", "restart", "circuit-open", "escalate"] as const);
    if (typeof receipt.decision !== "string" || !decisions.has(receipt.decision as "ignore")) throw new Error("invalid supervisor receipt decision");
    if (typeof receipt.supervisorId !== "string" || !receipt.supervisorId || receipt.supervisorId.length > 1024 || typeof receipt.childId !== "string" || !receipt.childId || receipt.childId.length > 1024 || typeof receipt.reason !== "string" || receipt.reason.length > 4096) throw new Error("invalid supervisor receipt text fields");
    if (!Number.isSafeInteger(receipt.at) || receipt.at < 0 || !Number.isSafeInteger(receipt.restartAttempt) || receipt.restartAttempt < 0) throw new Error("invalid supervisor receipt counters");
    const digest = (domain: string, value: string) => createHash("sha256").update(`tmux-subagents-supervisor-receipt:v1:${domain}\0${value}`).digest("hex").slice(0, 24);
    const supervisorId = `supervisor:${digest("supervisor-id", receipt.supervisorId)}`; const childId = `child:${digest("child-id", receipt.childId)}`; const key = digest("record-key", `${supervisorId}\0${childId}`); const message = receipt.reason.toLowerCase();
    const reasonCode = /timeout/.test(message) ? "TIMEOUT" : /auth|credential|nonce|token/.test(message) ? "AUTHENTICATION" : /circuit|backoff|restart|supervisor/.test(message) ? "SUPERVISION" : /owner|permission|symlink/.test(message) ? "OWNERSHIP" : "CHILD_FAILURE";
    await atomicWrite(this.confined(path.join(this.receiptsRoot, `${key}.json`)), `${JSON.stringify({ schemaVersion: 1, generation: this.generation, supervisorId, childId, decision: receipt.decision, reasonCode, at: receipt.at, restartAttempt: receipt.restartAttempt })}\n`, 16 * 1024);
  }

  async removeBinding(bindingId: string): Promise<void> {
    await unlink(this.confined(path.join(this.bindingsRoot, `${validIdentity(bindingId, "binding id")}.json`))).catch((error: NodeJS.ErrnoException) => {
      if (error.code !== "ENOENT") throw error;
    });
  }

  async removeTicket(ticket: ViewTicket, removeProjection = false): Promise<void> {
    for (const file of [this.ticketPath(ticket.ticketId), ticket.claimPath]) await unlink(this.confined(file)).catch((error: NodeJS.ErrnoException) => { if (error.code !== "ENOENT") throw error; });
    const entries = await readdir(this.ticketsRoot).catch((error: NodeJS.ErrnoException) => { if (error.code === "ENOENT") return [] as string[]; throw error; });
    for (const entry of entries) if (entry.startsWith(`${ticket.ticketId}.consumed.`)) await unlink(this.confined(path.join(this.ticketsRoot, entry))).catch((error: NodeJS.ErrnoException) => { if (error.code !== "ENOENT") throw error; });
    if (removeProjection) await unlink(this.confined(ticket.projectionPath)).catch((error: NodeJS.ErrnoException) => { if (error.code !== "ENOENT") throw error; });
  }

  async allTickets(): Promise<ViewTicket[]> {
    const entries = await readdir(this.ticketsRoot).catch(() => [] as string[]);
    const tickets: ViewTicket[] = [];
    for (const entry of entries) {
      const match = /^([A-Za-z0-9-]+)\.json$/.exec(entry);
      if (match) tickets.push(await this.readTicket(match[1], 0, true));
    }
    return tickets;
  }

  async allBindings(): Promise<ViewBinding[]> {
    const entries = await readdir(this.bindingsRoot).catch(() => [] as string[]);
    const bindings: ViewBinding[] = [];
    for (const entry of entries) {
      if (!entry.endsWith(".json")) continue;
      const file = this.confined(path.join(this.bindingsRoot, entry));
      const binding = object(JSON.parse(await secureRead(file, 16 * 1024)), "binding") as unknown as ViewBinding;
      if (binding.schemaVersion !== 1 || binding.generation !== this.generation || binding.ownerPiSessionId !== this.ownerPiSessionId) {
        throw new Error("stale binding has incompatible ownership");
      }
      bindings.push(binding);
    }
    return bindings;
  }

  async priorGenerations(): Promise<PrivateViewStore[]> {
    const entries = await readdir(this.generationsRoot).catch(() => [] as string[]);
    const stores: PrivateViewStore[] = [];
    for (const entry of entries) {
      if (entry === this.generation) continue;
      validIdentity(entry, "prior generation");
      const store = new PrivateViewStore(this.baseRoot, this.ownerPiSessionId, entry, { processIdentity: this.options.processIdentity });
      await assertOwned(store.generationRoot, true);
      stores.push(store);
    }
    return stores;
  }

  async expiredTickets(now = Date.now()): Promise<ViewTicket[]> {
    const expired: ViewTicket[] = [];
    for (const ticket of await this.allTickets()) if (ticket.expiresAt < now) expired.push(ticket);
    return expired;
  }

  private async removeGenerationAfterRename(validate: (movedLease: string) => Promise<void>): Promise<void> {
    await assertOwned(this.generationRoot, true); const movedRoot = path.join(this.generationsRoot, `.${this.generation}.removing.${randomUUID()}`); await rename(this.generationRoot, movedRoot);
    try { await validate(path.join(movedRoot, "owner-lease.json")); }
    catch (error) { try { await rename(movedRoot, this.generationRoot); } catch (restore) { throw new AggregateError([error, restore], "generation ownership race could not be restored"); } throw error; }
    await rm(movedRoot, { recursive: true, force: false });
  }

  async removeOwnedGeneration(): Promise<void> {
    if (!this.leaseStartIdentity) throw new Error("generation removal is indeterminate without process start identity");
    const before = object(JSON.parse(await secureRead(this.leasePath, 1024)), "generation lease"); if (!this.ownsLease(before)) throw new Error("generation ownership changed before owned removal");
    await this.options.beforeLeaseTransition?.("remove-owned"); await this.assertCurrentOwnerIdentity(); await this.removeGenerationAfterRename(async (movedLease) => { const lease = object(JSON.parse(await secureRead(movedLease, 1024)), "generation lease"); if (!this.ownsLease(lease)) throw new Error("generation ownership changed during owned removal"); await this.assertCurrentOwnerIdentity(); });
  }
}
