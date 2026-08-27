import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { chmod, mkdir, mkdtemp, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import test from "node:test";

const run = promisify(execFile);
const launcher = path.resolve("home/dot_local/bin/executable_workstation-tmux-subagents");

async function fixture(tamper = false) {
	const home = await mkdtemp(path.join(os.tmpdir(), "tmux-launcher-"));
	const extension = path.join(home, ".pi/agent/extensions/tmux-subagents");
	await mkdir(path.join(extension, "node_modules/xstate"), { recursive: true, mode: 0o700 });
	await mkdir(path.join(extension, "node_modules/terminal-kit"), { recursive: true, mode: 0o700 });
	const versions = { xstate: tamper ? "5.0.0" : "5.32.6", "terminal-kit": "3.1.4" };
	await writeFile(path.join(extension, "package.json"), JSON.stringify({ dependencies: { xstate: "5.32.6", "terminal-kit": "3.1.4" } }), { mode: 0o600 });
	await writeFile(path.join(extension, "package-lock.json"), JSON.stringify({ packages: { "node_modules/xstate": { version: versions.xstate }, "node_modules/terminal-kit": { version: versions["terminal-kit"] } } }), { mode: 0o600 });
	for (const [name, version] of Object.entries(versions)) await writeFile(path.join(extension, "node_modules", name, "package.json"), JSON.stringify({ version }), { mode: 0o600 });
	await mkdir(path.join(extension, "renderer"), { recursive: true, mode: 0o700 });
	const renderer = path.join(extension, "renderer/main.mjs");
	await writeFile(renderer, "#!/usr/bin/env node\nprocess.exit(0);\n", { mode: 0o700 });
	await chmod(renderer, 0o700);
	const tickets = path.join(home, "state/generations/generation/tickets");
	await mkdir(tickets, { recursive: true, mode: 0o700 });
	for (const directory of [path.join(home, "state"), path.join(home, "state/generations"), path.join(home, "state/generations/generation"), tickets]) await chmod(directory, 0o700);
	const ticket = path.join(tickets, "ticket.json");
	await writeFile(ticket, "{}\n", { mode: 0o600 });
	return { home, ticket, renderer };
}

test("standalone launcher attests locked JavaScript renderer before exec", { skip: process.platform === "win32" }, async () => {
	const valid = await fixture();
	await run(launcher, [process.execPath, valid.renderer, valid.ticket], { env: { ...process.env, HOME: valid.home } });
	const tampered = await fixture(true);
	await assert.rejects(run(launcher, [process.execPath, tampered.renderer, tampered.ticket], { env: { ...process.env, HOME: tampered.home } }), /xstate lock mismatch/);
	const missing = await fixture();
	await assert.rejects(run(launcher, [process.execPath, missing.renderer, path.join(missing.home, "state/generations/generation/tickets/missing.json")], { env: { ...process.env, HOME: missing.home } }), /ticket is missing/);
});
