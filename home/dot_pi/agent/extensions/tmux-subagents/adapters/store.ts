import { createHash, randomBytes, randomUUID } from "node:crypto";
import { constants, lstat, mkdir, open, readdir, realpath, rename, rm, unlink } from "node:fs/promises";
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
  readonly ownerPiSessionId: string;
  readonly generation: string;

  constructor(root: string, ownerPiSessionId: string, generation: string) {
    this.ownerPiSessionId = validIdentity(ownerPiSessionId, "Pi session id");
    this.generation = validIdentity(generation, "generation");
    this.baseRoot = path.resolve(root);
    this.sessionRoot = path.join(this.baseRoot, sessionKey(this.ownerPiSessionId));
    this.generationsRoot = path.join(this.sessionRoot, "generations");
    this.generationRoot = path.join(this.generationsRoot, this.generation);
    this.ticketsRoot = path.join(this.generationRoot, "tickets");
    this.projectionsRoot = path.join(this.generationRoot, "projections");
    this.bindingsRoot = path.join(this.generationRoot, "bindings");
    this.receiptsRoot = path.join(this.generationRoot, "supervisor-receipts");
    this.socketsRoot = path.join(this.generationRoot, "sockets");
  }

  private confined(file: string): string {
    const resolved = path.resolve(file);
    if (resolved !== this.generationRoot && !resolved.startsWith(`${this.generationRoot}${path.sep}`)) {
      throw new Error(`private record escapes generation root: ${file}`);
    }
    return resolved;
  }

  async initialize(): Promise<void> {
    for (const directory of [this.baseRoot, this.sessionRoot, this.generationsRoot, this.generationRoot, this.ticketsRoot, this.projectionsRoot, this.bindingsRoot, this.receiptsRoot, this.socketsRoot]) {
      await ensureDirectory(directory);
    }
    const canonical = await realpath(this.generationRoot);
    if (canonical !== this.generationRoot) throw new Error("private generation root is not canonical");
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
    const key = createHash("sha256").update(`${receipt.supervisorId}\0${receipt.childId}`).digest("hex").slice(0, 24);
    await atomicWrite(this.confined(path.join(this.receiptsRoot, `${key}.json`)), `${JSON.stringify({ schemaVersion: 1, generation: this.generation, ...receipt })}\n`, 16 * 1024);
  }

  async removeBinding(bindingId: string): Promise<void> {
    await unlink(this.confined(path.join(this.bindingsRoot, `${validIdentity(bindingId, "binding id")}.json`))).catch((error: NodeJS.ErrnoException) => {
      if (error.code !== "ENOENT") throw error;
    });
  }

  async removeTicket(ticket: ViewTicket, removeProjection = false): Promise<void> {
    for (const file of [this.ticketPath(ticket.ticketId), ticket.claimPath]) await unlink(this.confined(file)).catch(() => {});
    const entries = await readdir(this.ticketsRoot).catch(() => [] as string[]);
    for (const entry of entries) if (entry.startsWith(`${ticket.ticketId}.consumed.`)) await unlink(this.confined(path.join(this.ticketsRoot, entry))).catch(() => {});
    if (removeProjection) await unlink(this.confined(ticket.projectionPath)).catch(() => {});
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
      const store = new PrivateViewStore(this.baseRoot, this.ownerPiSessionId, entry);
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

  async removeGeneration(): Promise<void> {
    await assertOwned(this.generationRoot, true);
    await rm(this.generationRoot, { recursive: true, force: true });
  }
}
