import assert from "node:assert/strict";
import { mkdir, symlink, writeFile } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { RendererIpcServer, secureReapSocket } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/adapters/ipc-server.ts";
import type { ActorEvent } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/protocol/actor-events.ts";

async function fixture() {
	const base = path.join(os.tmpdir(), `ipc-${crypto.randomUUID()}`);
	const generationRoot = path.join(base, "session", "generations", "generation");
	await mkdir(generationRoot, { recursive: true, mode: 0o700 });
	for (const directory of [base, path.join(base, "session"), path.join(base, "session", "generations"), generationRoot]) await (await import("node:fs/promises")).chmod(directory, 0o700);
	const events: ActorEvent[] = [];
	const server = new RendererIpcServer(generationRoot, "generation", (event) => events.push(event));
	await server.start(); server.register({ ticketId: "ticket", generation: "generation", nonce: "secret", bindingId: "binding" });
	return { server, events };
}

function client(socketPath: string) {
	const socket = net.createConnection(socketPath); socket.setEncoding("utf8");
	let buffer = ""; const frames: any[] = [];
	socket.on("data", (chunk) => { buffer += chunk; while (buffer.includes("\n")) { const split = buffer.indexOf("\n"); const line = buffer.slice(0, split); buffer = buffer.slice(split + 1); if (line) frames.push(JSON.parse(line)); } });
	return { socket, frames };
}
async function until(predicate: () => boolean) { for (let attempt = 0; attempt < 100; attempt++) { if (predicate()) return; await new Promise((resolve) => setTimeout(resolve, 5)); } throw new Error("timed out"); }
function write(socket: net.Socket, value: unknown) { socket.write(`${JSON.stringify(value)}\n`); }

test("renderer IPC rotates reconnect credentials and permits one active connection per binding", async () => {
	const { server, events } = await fixture(); const first = client(server.socketPath);
	await new Promise((resolve) => first.socket.once("connect", resolve));
	write(first.socket, { version: 1, sequence: 1, type: "authenticate", ticketId: "ticket", generation: "generation", nonce: "secret" });
	await until(() => first.frames.some((frame) => frame.type === "authenticated"));
	const token1 = first.frames.find((frame) => frame.type === "authenticated").reconnectNonce;
	server.publish("binding", { schemaVersion: 1, generatedAt: 1, source: "pi-subagents-rpc", omitted: { runs: 0, children: 0, sourceByteLimitExceeded: false, projectionByteLimitExceeded: false }, runs: [] });
	await until(() => first.frames.some((frame) => frame.type === "snapshot"));
	write(first.socket, { version: 1, sequence: 2, type: "intent", intent: { kind: "refresh" } });
	await until(() => events.some((event) => event.type === "RENDER.INPUT"));
	const reconnect = client(server.socketPath); const replay = client(server.socketPath); await Promise.all([new Promise((resolve) => reconnect.socket.once("connect", resolve)), new Promise((resolve) => replay.socket.once("connect", resolve))]);
	write(reconnect.socket, { version: 1, sequence: 1, type: "authenticate", ticketId: "ticket", generation: "generation", nonce: token1, reconnect: true });
	write(replay.socket, { version: 1, sequence: 1, type: "authenticate", ticketId: "ticket", generation: "generation", nonce: token1, reconnect: true });
	await until(() => reconnect.frames.length > 0 && replay.frames.length > 0);
	const authenticated = [reconnect, replay].filter((candidate) => candidate.frames.some((frame) => frame.type === "authenticated")); const rejected = [reconnect, replay].filter((candidate) => candidate.frames.some((frame) => frame.type === "fatal"));
	assert.equal(authenticated.length, 1); assert.equal(rejected.length, 1); assert.notEqual(authenticated[0].frames.find((frame) => frame.type === "authenticated").reconnectNonce, token1); assert.match(rejected[0].frames.at(-1).message, /authentication failed/); await until(() => first.socket.destroyed);
	reconnect.socket.destroy(); replay.socket.destroy(); await server.stop();
});

test("renderer IPC rejects unconfirmed privileged intents", async () => {
	const { server } = await fixture(); const c = client(server.socketPath); await new Promise((resolve) => c.socket.once("connect", resolve));
	write(c.socket, { version: 1, sequence: 1, type: "authenticate", ticketId: "ticket", generation: "generation", nonce: "secret" });
	await until(() => c.frames.some((frame) => frame.type === "authenticated"));
	write(c.socket, { version: 1, sequence: 2, type: "intent", intent: { kind: "stop", confirmed: false } });
	await until(() => c.frames.some((frame) => frame.type === "fatal"));
	assert.match(c.frames.at(-1).message, /confirmation/);
	c.socket.destroy(); await server.stop();
});

test("aggregate rate limits survive reconnect and cannot be bypassed", async () => {
	const { server } = await fixture(); const first = client(server.socketPath); await new Promise((resolve) => first.socket.once("connect", resolve));
	write(first.socket, { version: 1, sequence: 1, type: "authenticate", ticketId: "ticket", generation: "generation", nonce: "secret" }); await until(() => first.frames.some((frame) => frame.type === "authenticated"));
	const token = first.frames[0].reconnectNonce;
	for (let sequence = 2; sequence <= 21; sequence++) write(first.socket, { version: 1, sequence, type: "intent", intent: { kind: "refresh" } });
	const reconnect = client(server.socketPath); await new Promise((resolve) => reconnect.socket.once("connect", resolve));
	write(reconnect.socket, { version: 1, sequence: 1, type: "authenticate", ticketId: "ticket", generation: "generation", nonce: token, reconnect: true }); await until(() => reconnect.frames.some((frame) => frame.type === "authenticated"));
	write(reconnect.socket, { version: 1, sequence: 2, type: "intent", intent: { kind: "refresh" } }); await until(() => reconnect.frames.some((frame) => frame.type === "fatal"));
	assert.match(reconnect.frames.at(-1).message, /rate exceeded/); first.socket.destroy(); reconnect.socket.destroy(); await server.stop();
});

test("socket cleanup reaps crash leftovers but refuses symlinks and non-sockets", async () => {
	const base = path.join(os.tmpdir(), `ipc-leftover-${crypto.randomUUID()}`); const sockets = path.join(base, "sockets"); await mkdir(sockets, { recursive: true, mode: 0o700 });
	const socketPath = path.join(sockets, "renderer.sock"); const crashed = net.createServer(); await new Promise<void>((resolve, reject) => { crashed.once("error", reject); crashed.listen(socketPath, resolve); }); await new Promise<void>((resolve) => crashed.close(() => resolve()));
	await secureReapSocket(socketPath);
	const target = path.join(base, "target"); await writeFile(target, "foreign"); await symlink(target, socketPath); await assert.rejects(secureReapSocket(socketPath), /non-socket/);
});

test("renderer IPC rejects oversized input before JSON parsing", async () => {
	const { server } = await fixture(); const c = client(server.socketPath); await new Promise((resolve) => c.socket.once("connect", resolve));
	c.socket.write("x".repeat(70 * 1024));
	await until(() => c.frames.some((frame) => frame.type === "fatal"));
	assert.match(c.frames.at(-1).message, /byte limit/);
	c.socket.destroy(); await server.stop();
});
