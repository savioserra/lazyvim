import assert from "node:assert/strict";
import { chmod, mkdir, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { attestRuntime, type RuntimeConfig } from "../../../home/dot_pi/agent/extensions/tmux-subagents/adapters/runtime-attestation.ts";

const config: RuntimeConfig = { enabled: true, xstateVersion: "5.32.6", terminalKitVersion: "3.1.4", actorProtocolVersion: 1 };
const posixOnly = { skip: process.platform === "win32" };

async function fixture(native = false) {
	const actual = path.join(os.tmpdir(), `tmux-runtime-${crypto.randomUUID()}`);
	await mkdir(path.join(actual, "node_modules/xstate"), { recursive: true, mode: 0o700 });
	await mkdir(path.join(actual, "node_modules/terminal-kit"), { recursive: true, mode: 0o700 });
	await mkdir(path.join(actual, "renderer"), { recursive: true, mode: 0o700 });
	await writeFile(path.join(actual, "renderer/main.mjs"), "#!/usr/bin/env node\n", { mode: 0o700 });
	await writeFile(path.join(actual, "node_modules/xstate/package.json"), JSON.stringify({ version: "5.32.6" }), { mode: 0o600 });
	await writeFile(path.join(actual, "node_modules/terminal-kit/package.json"), JSON.stringify({ version: "3.1.4" }), { mode: 0o600 });
	if (native) await writeFile(path.join(actual, "node_modules/terminal-kit/addon.node"), "native", { mode: 0o600 });
	return actual;
}

test("runtime attests exact locked JavaScript dependencies and renderer", posixOnly, async () => {
	const root = await fixture();
	const attestation = await attestRuntime(config, { root, platform: "linux" });
	assert.equal(attestation.xstateVersion, "5.32.6");
	assert.equal(attestation.terminalKitVersion, "3.1.4");
	assert.equal(attestation.nodePath, process.execPath);
});

test("runtime fails closed for incompatible, unsafe, native, and scripted POSIX dependencies", posixOnly, async () => {
	const root = await fixture();
	await assert.rejects(attestRuntime({ ...config, xstateVersion: "5.0.0" }, { root }), /does not match/);
	await chmod(path.join(root, "renderer/main.mjs"), 0o722);
	await assert.rejects(attestRuntime(config, { root }), /writable/);
	const native = await fixture(true);
	await assert.rejects(attestRuntime(config, { root: native }), /native module/);
	const scripted = await fixture();
	await writeFile(path.join(scripted, "node_modules/terminal-kit/package.json"), JSON.stringify({ version: "3.1.4", scripts: { postinstall: "compile" } }), { mode: 0o600 });
	await assert.rejects(attestRuntime(config, { root: scripted }), /lifecycle script postinstall/);
});
