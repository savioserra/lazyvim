import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import test from "node:test";
import { TmuxController } from "../../../home/dot_pi/private_agent/extensions/tmux-subagents/adapters/tmux.ts";

const run = promisify(execFile);

test("isolated tmux server preserves adopted panes and closes only created panes", { skip: process.platform === "win32" }, async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), "tmux-subagents-integration-"));
	const socket = path.join(root, "server.sock");
	await run("tmux", ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "observer"]);
	try {
		const controller = new TmuxController(socket);
		const created = await controller.createPane(root);
		assert.match(created.paneId, /^%\d+$/);
		await assert.rejects(
			controller.closeCreated({
				schemaVersion: 1,
				bindingId: "adopted",
				generation: "generation",
				ownerPiSessionId: "session",
				runId: "run",
				created: false,
				projectionPath: path.join(root, "projection"),
				pane: created,
				createdAt: Date.now(),
			}),
			/adopted/,
		);
		assert.deepEqual(await controller.inspectPane(created.paneId), created);
		await assert.rejects(
			controller.closeCreated({
				schemaVersion: 1,
				bindingId: "stale-created",
				generation: "generation",
				ownerPiSessionId: "session",
				runId: "run",
				created: true,
				projectionPath: path.join(root, "projection"),
				pane: { ...created, panePid: created.panePid + 1 },
				createdAt: Date.now(),
			}),
			/identity changed before action/,
		);
		assert.deepEqual(await controller.inspectPane(created.paneId), created);
		await controller.closeCreated({
			schemaVersion: 1,
			bindingId: "created",
			generation: "generation",
			ownerPiSessionId: "session",
			runId: "run",
			created: true,
			projectionPath: path.join(root, "projection"),
			pane: created,
			createdAt: Date.now(),
		});
		await assert.rejects(controller.inspectPane(created.paneId));
	} finally {
		await run("tmux", ["-S", socket, "kill-server"]).catch(() => {});
	}
});

test("server replacement cannot focus or kill a reused pane id", { skip: process.platform === "win32" }, async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), "tmux-subagents-server-race-"));
	const socket = path.join(root, "server.sock");
	await run("tmux", ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "first"]);
	const controller = new TmuxController(socket);
	const original = await controller.inspectPane("%0");
	await run("tmux", ["-S", socket, "kill-server"]);
	await run("tmux", ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "second"]);
	try {
		await assert.rejects(controller.focusPane(original), /identity changed before action/);
		await assert.rejects(controller.closeCreated({ schemaVersion: 1, bindingId: "stale", generation: "g", ownerPiSessionId: "s", runId: "r", created: true, projectionPath: "/tmp/p", pane: original, createdAt: 1 }), /identity changed before action/);
		const replacement = await controller.inspectPane("%0");
		assert.equal(replacement.sessionId !== original.sessionId || replacement.panePid !== original.panePid, true);
	} finally {
		await run("tmux", ["-S", socket, "kill-server"]).catch(() => {});
	}
});

test("automatic topology creates deterministic owned windows, reuses panes, and leaves the foreign session pane intact", { skip: process.platform === "win32" }, async () => {
	const root = await mkdtemp(path.join(os.tmpdir(), "tmux-subagents-topology-"));
	const socket = path.join(root, "server.sock");
	await run("tmux", ["-S", socket, "-f", "/dev/null", "new-session", "-d", "-s", "observer"]);
	try {
		const controller = new TmuxController(socket); const original = await controller.inspectPane("%0"); const created = [];
		for (let index = 0; index < 5; index++) created.push(await controller.openOwnedPane({ cwd: root, command: "sleep 30", owner: "generation-owner", windowName: "subagents", maxPanesPerWindow: 4, maxWindows: 2 }));
		assert.equal(new Set(created.map((pane) => pane.paneId)).size, 5);
		await controller.focusPane(created.at(-1)!);
		assert.deepEqual(await controller.inspectPane(original.paneId), original, "foreign pane identity must remain unchanged");
		const { stdout } = await run("tmux", ["-S", socket, "list-windows", "-F", "#{window_panes}\t#{@workstation_tmux_subagents_owner}"]);
		const owned = stdout.trim().split("\n").filter((line) => line.endsWith("\tgeneration-owner"));
		assert.deepEqual(owned.sort(), ["1\tgeneration-owner", "4\tgeneration-owner"]);
	} finally { await run("tmux", ["-S", socket, "kill-server"]).catch(() => {}); }
});
