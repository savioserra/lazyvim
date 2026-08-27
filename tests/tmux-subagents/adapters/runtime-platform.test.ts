import assert from "node:assert/strict";
import test from "node:test";
import { attestRuntime, type RuntimeConfig } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/adapters/runtime-attestation.ts";

const config: RuntimeConfig = { enabled: true, xstateVersion: "5.32.6", terminalKitVersion: "3.1.4", actorProtocolVersion: 1 };
const unusedRoot = "runtime-path-must-not-be-read";

test("runtime rejects disabled configuration before filesystem attestation", async () => {
	await assert.rejects(attestRuntime({ ...config, enabled: false }, { root: unusedRoot, platform: "linux" }), /disabled/);
});

test("runtime rejects Windows before filesystem attestation", async () => {
	await assert.rejects(attestRuntime(config, { root: unusedRoot, platform: "win32" }), /unavailable on Windows/);
});

test("runtime rejects an incompatible actor protocol before filesystem attestation", async () => {
	await assert.rejects(attestRuntime({ ...config, actorProtocolVersion: 2 }, { root: unusedRoot, platform: "linux" }), /actor protocol is incompatible/);
});
