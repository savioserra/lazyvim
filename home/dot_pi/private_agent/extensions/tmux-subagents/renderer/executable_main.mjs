#!/usr/bin/env node
import { constants } from "node:fs";
import { lstat, open, realpath } from "node:fs/promises";
import path from "node:path";
import { RendererTransport } from "./transport.mjs";
import { RendererUi } from "./ui.mjs";

const ticketPath = process.argv[2];
function blocked(message) { process.stderr.write(`tmux-subagents renderer blocked: ${message}\n`); process.exit(69); }
async function privatePath(file, directory) {
  const stat = await lstat(file); if (stat.isSymbolicLink() || (directory ? !stat.isDirectory() : !stat.isFile())) throw new Error(`${file} has incompatible type`);
  if (typeof process.getuid === "function" && stat.uid !== process.getuid()) throw new Error(`${file} has foreign ownership`);
  const expected = directory ? 0o700 : 0o600; if ((stat.mode & 0o777) !== expected) throw new Error(`${file} must have mode ${expected.toString(8)}`);
}
async function secureTicket(file) {
  const handle = await open(file, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try { const stat = await handle.stat(); if (!stat.isFile() || stat.size > 8192 || (typeof process.getuid === "function" && stat.uid !== process.getuid()) || (stat.mode & 0o777) !== 0o600) throw new Error("ticket changed during secure open"); return JSON.parse(await handle.readFile("utf8")); }
  finally { await handle.close(); }
}
function cleanup(code = 0) { transport?.close(); ui?.stop(); process.exit(code); }
let transport; let ui;
try {
  if (!ticketPath || !path.isAbsolute(ticketPath) || !ticketPath.includes(`${path.sep}generations${path.sep}`) || !ticketPath.endsWith(".json")) blocked("ticket path is invalid");
  await privatePath(ticketPath, false); if (await realpath(ticketPath) !== ticketPath) blocked("ticket path is not canonical");
  const ticketsRoot = path.dirname(ticketPath); const generationRoot = path.dirname(ticketsRoot); const socketsRoot = path.join(generationRoot, "sockets");
  await privatePath(ticketsRoot, true); await privatePath(generationRoot, true);
  const ticket = await secureTicket(ticketPath);
  if (ticket.schemaVersion !== 1 || typeof ticket.ticketId !== "string" || typeof ticket.nonce !== "string" || typeof ticket.generation !== "string" || typeof ticket.claimPath !== "string" || typeof ticket.rendererSocketPath !== "string" || typeof ticket.nodePath !== "string" || typeof ticket.rendererPath !== "string" || ticket.expiresAt < Date.now()) blocked("ticket is incompatible or expired");
  if (await realpath(process.execPath) !== ticket.nodePath || await realpath(new URL(import.meta.url)) !== ticket.rendererPath) blocked("renderer runtime does not match its attested executable");
  if (path.dirname(ticket.claimPath) !== ticketsRoot || path.dirname(ticket.rendererSocketPath) !== socketsRoot || path.basename(ticket.rendererSocketPath) !== "renderer.sock" || !process.env.TMUX || !/^%[0-9]+$/.test(process.env.TMUX_PANE ?? "")) blocked("renderer must run in the claimed tmux pane with private IPC");
  const claim = `${JSON.stringify({ schemaVersion: 1, ticketId: ticket.ticketId, nonce: ticket.nonce, tmux: process.env.TMUX, paneId: process.env.TMUX_PANE, claimedAt: Date.now() })}\n`;
  const handle = await open(ticket.claimPath, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY | (constants.O_NOFOLLOW ?? 0), 0o600);
  await handle.writeFile(claim); await handle.sync(); await handle.close();
  ui = new RendererUi((intent) => transport.intent(intent), cleanup);
  transport = new RendererTransport(ticket, { frame: (frame) => ui.update(frame), error: (error) => { ui.delivery = error.message; ui.render(); }, reconnecting: (delay) => { ui.delivery = `IPC reconnect in ${delay}ms`; ui.render(); }, close: () => cleanup(0) });
  transport.connect(); ui.start();
} catch (error) { blocked(error instanceof Error ? error.message : String(error)); }
