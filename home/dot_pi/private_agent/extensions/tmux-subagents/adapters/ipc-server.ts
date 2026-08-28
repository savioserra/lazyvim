import { randomBytes, timingSafeEqual } from "node:crypto";
import { chmod, lstat, mkdir, unlink } from "node:fs/promises";
import net, { type Server, type Socket } from "node:net";
import path from "node:path";
import type { ActorEvent } from "../protocol/actor-events.ts";
import { IPC_SCHEMA_VERSION, MAX_INPUTS_PER_SECOND, MAX_IPC_FRAME_BYTES, type ServerFrame } from "../protocol/ipc-envelope.ts";
import { assertActorEvent, assertRendererIntent, parseClientFrame } from "../protocol/validators.ts";
import type { Projection } from "../domain/projection.ts";

export interface RendererTicketRegistration {
  ticketId: string;
  generation: string;
  nonce: string;
  bindingId: string;
}

interface Session extends RendererTicketRegistration {
  reconnectNonce: string;
  activeConnectionId?: string;
  recentInputs: number[];
}

interface Connection {
  id: string;
  socket: Socket;
  inputSequence: number;
  outputSequence: number;
  ticketId: string;
  bindingId: string;
}

function sameSecret(actual: string, expected: string): boolean {
  const a = Buffer.from(actual); const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}
function reconnectCredential(): string { return randomBytes(32).toString("base64url"); }
function currentUid(): number | undefined { return typeof process.getuid === "function" ? process.getuid() : undefined; }

async function assertPrivateDirectory(directory: string): Promise<void> {
  const metadata = await lstat(directory);
  if (!metadata.isDirectory() || metadata.isSymbolicLink()) throw new Error("IPC parent must be a regular directory");
  if (currentUid() !== undefined && metadata.uid !== currentUid()) throw new Error("IPC parent has foreign ownership");
  if ((metadata.mode & 0o777) !== 0o700) throw new Error("IPC parent must be owner-private");
}

/** Reap only an exact, owned Unix socket. Symlinks, files, and foreign ownership fail closed. */
export async function secureReapSocket(socketPath: string): Promise<void> {
  let metadata;
  try { metadata = await lstat(socketPath); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return; throw error; }
  if (metadata.isSymbolicLink() || !metadata.isSocket()) throw new Error("refusing to reap a non-socket IPC path");
  if (currentUid() !== undefined && metadata.uid !== currentUid()) throw new Error("refusing to reap a foreign-owned IPC socket");
  await unlink(socketPath);
}

export interface IpcObservation { kind: "parse" | "authentication" | "rate-limit" | "timeout" | "socket"; error: Error; bindingId?: string }

export class RendererIpcServer {
  readonly socketPath: string;
  private server?: Server;
  private readonly tickets = new Map<string, RendererTicketRegistration>();
  private readonly sessions = new Map<string, Session>();
  private readonly latest = new Map<string, { projection: Projection; metadata: { delivery?: { ok: boolean; message: string }; supervisors?: Record<string, string> } }>();
  private readonly connections = new Map<string, Connection>();
  private readonly activeBindings = new Map<string, string>();
  private nextConnection = 0;
  private readonly generation: string;
  private readonly emitEvent: (event: ActorEvent) => void;
  private readonly reportFailure: (error: Error) => void;
  private readonly observeFailure: (event: IpcObservation) => void;
  private observationTimes: number[] = [];
  private stopping?: Promise<void>;

  constructor(generationRoot: string, generation: string, emit: (event: ActorEvent) => void, reportFailure: (error: Error) => void = () => {}, observeFailure: (event: IpcObservation) => void = () => {}) {
    this.socketPath = path.join(generationRoot, "sockets", "renderer.sock");
    this.generation = generation;
    this.emitEvent = emit;
    this.reportFailure = reportFailure;
    this.observeFailure = observeFailure;
  }

  private observe(event: IpcObservation): void {
    const now = Date.now(); this.observationTimes = this.observationTimes.filter((at) => now - at < 1000); if (this.observationTimes.length >= 10) return; this.observationTimes.push(now); this.observeFailure(event);
  }

  register(ticket: RendererTicketRegistration): void {
    if (ticket.generation !== this.generation || !ticket.ticketId || !ticket.nonce) throw new Error("renderer ticket belongs to another generation");
    this.tickets.set(ticket.ticketId, { ...ticket });
  }

  revoke(ticketId: string): void {
    const registration = this.tickets.get(ticketId) ?? this.sessions.get(ticketId);
    this.tickets.delete(ticketId);
    const session = this.sessions.get(ticketId);
    if (session?.activeConnectionId) this.connections.get(session.activeConnectionId)?.socket.destroy();
    if (registration && this.activeBindings.get(registration.bindingId) === session?.activeConnectionId) this.activeBindings.delete(registration.bindingId);
    this.sessions.delete(ticketId);
    if (registration) this.latest.delete(registration.bindingId);
  }

  async start(): Promise<void> {
    if (process.platform === "win32") throw new Error("tmux-subagents IPC is unavailable on Windows");
    await mkdir(path.dirname(this.socketPath), { recursive: true, mode: 0o700 });
    await assertPrivateDirectory(path.dirname(this.socketPath));
    await secureReapSocket(this.socketPath);
    this.server = net.createServer((socket) => this.accept(socket));
    this.server.maxConnections = 32;
    await new Promise<void>((resolve, reject) => {
      this.server!.once("error", reject);
      this.server!.listen(this.socketPath, () => { this.server!.off("error", reject); resolve(); });
    });
    this.server.on("error", (error) => this.reportFailure(error));
    await chmod(this.socketPath, 0o600);
  }

  private accept(socket: Socket): void {
    socket.setTimeout(30_000);
    let buffer = "";
    let connection: Connection | undefined;
    const fail = (message: string) => {
      if (!socket.destroyed) socket.end(`${JSON.stringify({ version: 1, sequence: 1, type: "fatal", message } satisfies ServerFrame)}\n`);
    };
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      if (Buffer.byteLength(buffer, "utf8") > MAX_IPC_FRAME_BYTES) { fail("IPC input exceeds byte limit"); return; }
      while (buffer.includes("\n")) {
        const split = buffer.indexOf("\n"); const line = buffer.slice(0, split); buffer = buffer.slice(split + 1);
        if (!line) continue;
        try {
          const frame = parseClientFrame(line);
          if (!connection) {
            if (frame.type !== "authenticate") throw new Error("first IPC frame must authenticate");
            if (frame.generation !== this.generation) throw new Error("renderer authentication failed");
            const firstUse = this.tickets.get(frame.ticketId);
            const existing = this.sessions.get(frame.ticketId);
            const registration = firstUse && frame.reconnect !== true && sameSecret(frame.nonce, firstUse.nonce)
              ? firstUse
              : existing && frame.reconnect === true && sameSecret(frame.nonce, existing.reconnectNonce) ? existing : undefined;
            if (!registration) throw new Error("renderer authentication failed");
            const id = `${this.generation}:${++this.nextConnection}`;
            const session: Session = existing ?? { ...registration, reconnectNonce: "", recentInputs: [] };
            const priorId = this.activeBindings.get(registration.bindingId) ?? session.activeConnectionId;
            const prior = priorId ? this.connections.get(priorId) : undefined;
            session.reconnectNonce = reconnectCredential();
            session.activeConnectionId = id;
            this.tickets.delete(frame.ticketId);
            this.sessions.set(frame.ticketId, session);
            this.activeBindings.set(registration.bindingId, id);
            connection = { id, socket, inputSequence: frame.sequence, outputSequence: 0, ticketId: frame.ticketId, bindingId: registration.bindingId };
            this.connections.set(id, connection);
            if (prior && prior.id !== id) prior.socket.destroy(new Error("renderer connection replaced by authenticated reconnect"));
            this.send(id, { type: "authenticated", connectionId: id, reconnectNonce: session.reconnectNonce });
            const latest = this.latest.get(registration.bindingId);
            if (latest) this.send(id, { type: "snapshot", projection: latest.projection, ...latest.metadata });
            this.emitEvent({ type: "RENDER.CONNECTED", connectionId: id, bindingId: registration.bindingId });
            continue;
          }
          if (frame.sequence <= connection.inputSequence) throw new Error("replayed or out-of-order IPC frame");
          connection.inputSequence = frame.sequence;
          const session = this.sessions.get(connection.ticketId);
          if (!session || session.activeConnectionId !== connection.id) throw new Error("renderer connection is no longer active");
          const now = Date.now(); session.recentInputs = session.recentInputs.filter((at) => now - at < 1000);
          if (session.recentInputs.length >= MAX_INPUTS_PER_SECOND) throw new Error("renderer input rate exceeded");
          session.recentInputs.push(now);
          if (frame.type !== "intent") throw new Error("renderer is already authenticated");
          const intent = assertRendererIntent(frame.intent);
          assertActorEvent({ type: "RENDER.INPUT", connectionId: connection.id, intent });
          this.emitEvent({ type: "RENDER.INPUT", connectionId: connection.id, intent });
        } catch (error) { const failure = error instanceof Error ? error : new Error(String(error)); const kind = /authenticate|authentication/.test(failure.message) ? "authentication" : /rate exceeded/.test(failure.message) ? "rate-limit" : "parse"; this.observe({ kind, error: failure, ...(connection ? { bindingId: connection.bindingId } : {}) }); fail(failure.message); }
      }
    });
    socket.on("timeout", () => { this.observe({ kind: "timeout", error: new Error("renderer IPC timeout"), ...(connection ? { bindingId: connection.bindingId } : {}) }); socket.destroy(new Error("renderer IPC timeout")); });
    socket.on("close", () => {
      if (!connection) return;
      this.connections.delete(connection.id);
      const session = this.sessions.get(connection.ticketId);
      if (session?.activeConnectionId === connection.id) session.activeConnectionId = undefined;
      if (this.activeBindings.get(connection.bindingId) === connection.id) this.activeBindings.delete(connection.bindingId);
      this.emitEvent({ type: "RENDER.DISCONNECTED", connectionId: connection.id, bindingId: connection.bindingId, reason: "renderer socket closed" });
    });
    socket.on("error", (error) => this.observe({ kind: "socket", error, ...(connection ? { bindingId: connection.bindingId } : {}) }));
  }

  bindingFor(connectionId: string): string | undefined { return this.connections.get(connectionId)?.bindingId; }

  send(connectionId: string, frame: Omit<ServerFrame, "version" | "sequence">): void {
    const connection = this.connections.get(connectionId);
    if (!connection || connection.socket.destroyed) return;
    const encoded = `${JSON.stringify({ version: IPC_SCHEMA_VERSION, sequence: ++connection.outputSequence, ...frame })}\n`;
    if (Buffer.byteLength(encoded, "utf8") > MAX_IPC_FRAME_BYTES) throw new Error("outbound IPC frame exceeds byte limit");
    connection.socket.write(encoded);
  }

  publish(bindingId: string, projection: Projection, metadata: { delivery?: { ok: boolean; message: string }; supervisors?: Record<string, string> } = {}): void {
    this.latest.set(bindingId, { projection, metadata });
    for (const connection of this.connections.values()) if (connection.bindingId === bindingId) this.send(connection.id, { type: "snapshot", projection, ...metadata });
  }

  async stop(): Promise<void> {
    if (this.stopping) return this.stopping;
    this.stopping = (async () => {
      for (const connection of this.connections.values()) connection.socket.destroy();
      this.connections.clear(); this.activeBindings.clear(); this.tickets.clear(); this.sessions.clear(); this.latest.clear();
      const server = this.server; this.server = undefined; if (server) await new Promise<void>((resolve) => server.close(() => resolve()));
      await secureReapSocket(this.socketPath);
    })();
    try { await this.stopping; } finally { this.stopping = undefined; }
  }
}
