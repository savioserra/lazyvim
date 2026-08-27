import assert from "node:assert/strict";
import test from "node:test";
import { socketFromTmuxEnvironment, TmuxController, type CommandExecutor } from "../../../home/dot_pi/agent/extensions/tmux-subagents/adapters/tmux.ts";
import type { ViewBinding } from "../../../home/dot_pi/agent/extensions/tmux-subagents/adapters/store.ts";

const identity = { socketPath: "/tmp/tmux-1000/default", paneId: "%2", panePid: 123, paneTty: "/dev/pts/2", sessionId: "$1" };

function binding(created: boolean): ViewBinding {
	return {
		schemaVersion: 1,
		bindingId: "binding-1",
		generation: "generation-1",
		ownerPiSessionId: "session-1",
		runId: "run-1",
		created,
		projectionPath: "/tmp/projection",
		pane: identity,
		createdAt: 1,
	};
}

test("tmux environment parser preserves the socket and rejects malformed data", () => {
	assert.equal(socketFromTmuxEnvironment("/tmp/tmux-1000/default,123,0"), "/tmp/tmux-1000/default");
	assert.throws(() => socketFromTmuxEnvironment("not-tmux"), /valid server socket/);
});

test("controller uses argv without a shell for create and inspect", async () => {
	const calls: Array<{ file: string; args: readonly string[] }> = [];
	const execute: CommandExecutor = async (file, args) => {
		calls.push({ file, args });
		return { stdout: "%2\t123\t/dev/pts/2\t$1\n", stderr: "" };
	};
	const controller = new TmuxController(identity.socketPath, execute);
	assert.deepEqual(await controller.createPane("/repo with spaces;touch /tmp/no"), identity);
	assert.equal(calls[0]?.file, "tmux");
	assert.deepEqual(calls[0]?.args, ["-S", identity.socketPath, "split-window", "-d", "-P", "-F", "#{pane_id}\t#{pane_pid}\t#{pane_tty}\t#{session_id}", "-c", "/repo with spaces;touch /tmp/no"]);
});

test("adopted panes can never be killed", async () => {
	const controller = new TmuxController(identity.socketPath, async () => {
		throw new Error("executor must not run");
	});
	await assert.rejects(controller.closeCreated(binding(false)), /refusing to close an adopted/);
});

test("created pane close verifies the full tuple before kill", async () => {
	const calls: readonly string[][] = [];
	const mutableCalls = calls as string[][];
	const execute: CommandExecutor = async (_file, args) => {
		mutableCalls.push([...args]);
		return { stdout: "%2\t123\t/dev/pts/2\t$1\n", stderr: "" };
	};
	await new TmuxController(identity.socketPath, execute).closeCreated(binding(true));
	const action = mutableCalls.at(-1) ?? [];
	assert.deepEqual(action.slice(0, 7), ["-S", identity.socketPath, "if-shell", "-F", "-t", "%2", action[6]]);
	assert.match(action[6] ?? "", /pane_pid.*123/);
	assert.equal(action[7], "kill-pane -t %2");
	assert.equal(mutableCalls.length, 1, "identity check and kill must use one tmux command queue");

	const changed: CommandExecutor = async () => ({ stdout: "__TMUX_SUBAGENTS_IDENTITY_MISMATCH__\n", stderr: "" });
	await assert.rejects(new TmuxController(identity.socketPath, changed).closeCreated(binding(true)), /identity changed before action/);
});

test("pane disappearance is view failure only", async () => {
	const missing: CommandExecutor = async () => {
		throw new Error("can't find pane: %2");
	};
	await assert.rejects(new TmuxController(identity.socketPath, missing).focusPane(identity), /can't find pane/);
});

test("owned topology reuses bounded windows, applies tiled layout, and never uses send-keys", async () => {
	const calls: string[][] = []; let paneLists = 0;
	const owned = (id: string, pid: number, tty: string) => `${id}\t${pid}\t${tty}\t$1\towner-1\t${id}\t${pid}\t${tty}\t$1`;
	const execute: CommandExecutor = async (_file, args) => {
		calls.push([...args]); const command = args[2];
		if (command === "list-windows") return { stdout: "@1\t1\towner-1\t$1\n@2\t4\tforeign\t$1\n", stderr: "" };
		if (command === "list-panes") return { stdout: paneLists++ === 0 ? `${owned("%1", 111, "/dev/pts/1")}\n` : `${owned("%1", 111, "/dev/pts/1")}\n${owned("%2", 123, "/dev/pts/2")}\n`, stderr: "" };
		if (command === "split-window") return { stdout: "%2\t123\t/dev/pts/2\t$1\n", stderr: "" };
		return { stdout: "", stderr: "" };
	};
	const pane = await new TmuxController(identity.socketPath, execute).openOwnedPane({ cwd: "/repo", command: "'/bin/renderer' '/private/ticket'", owner: "owner-1", maxPanesPerWindow: 4, maxWindows: 2 });
	assert.deepEqual(pane, identity);
	assert.ok(calls.some((args) => args.includes("split-window") && args.includes("@1") && args.at(-1) === "'/bin/renderer' '/private/ticket'"));
	assert.ok(calls.some((args) => args.includes("select-layout") && args.at(-1) === "tiled"));
	assert.equal(calls.some((args) => args.includes("send-keys")), false);
});

test("owned topology rolls back a newly created pane when layout reconciliation fails", async () => {
	const calls: string[][] = []; let paneLists = 0;
	const owned = (id: string, pid: number, tty: string) => `${id}\t${pid}\t${tty}\t$1\towner-1\t${id}\t${pid}\t${tty}\t$1`;
	const execute: CommandExecutor = async (_file, args) => {
		calls.push([...args]); const command = args[2];
		if (command === "list-windows") return { stdout: "@1\t1\towner-1\t$1\n", stderr: "" };
		if (command === "list-panes") return { stdout: paneLists++ === 0 ? `${owned("%1", 111, "/dev/pts/1")}\n` : `${owned("%1", 111, "/dev/pts/1")}\n${owned("%2", 123, "/dev/pts/2")}\n`, stderr: "" };
		if (command === "split-window") return { stdout: "%2\t123\t/dev/pts/2\t$1\n", stderr: "" };
		if (command === "select-layout") throw new Error("layout failed");
		return { stdout: "", stderr: "" };
	};
	await assert.rejects(new TmuxController(identity.socketPath, execute).openOwnedPane({ cwd: "/repo", command: "renderer", owner: "owner-1" }), /layout failed/);
	assert.ok(calls.some((args) => args.includes("if-shell") && args.includes("kill-pane -t %2")), "rollback must use an identity-guarded kill");
});

test("mixed owned windows are left untouched and a fully owned window is created", async () => {
	const calls: string[][] = [];
	const execute: CommandExecutor = async (_file, args) => {
		calls.push([...args]); const command = args[2];
		if (command === "list-windows") return { stdout: "@1\t2\towner-1\t$1\n", stderr: "" };
		if (command === "list-panes") return { stdout: "%1\t111\t/dev/pts/1\t$1\towner-1\t%1\t111\t/dev/pts/1\t$1\n%9\t999\t/dev/pts/9\t$1\t\t\t0\t\t\n", stderr: "" };
		if (command === "new-window") return { stdout: "%2\t123\t/dev/pts/2\t$1\n", stderr: "" };
		if (command === "display-message") return { stdout: "@2\n", stderr: "" };
		return { stdout: "", stderr: "" };
	};
	await new TmuxController(identity.socketPath, execute).openOwnedPane({ cwd: "/repo", command: "renderer", owner: "owner-1", maxWindows: 2 });
	assert.equal(calls.some((args) => args.includes("split-window")), false);
	assert.equal(calls.some((args) => args.includes("select-layout") && args.includes("@1")), false);
	assert.ok(calls.some((args) => args.includes("new-window")));
});

test("owned topology fails closed at its overflow limit without touching foreign windows", async () => {
	const calls: string[][] = [];
	const execute: CommandExecutor = async (_file, args) => {
		calls.push([...args]);
		return { stdout: "@1\t4\towner-1\t$1\n@2\t4\towner-1\t$1\n@3\t4\tforeign\t$1\n", stderr: "" };
	};
	await assert.rejects(new TmuxController(identity.socketPath, execute).openOwnedPane({ cwd: "/repo", command: "renderer", owner: "owner-1", maxPanesPerWindow: 4, maxWindows: 2 }), /topology overflow/);
	assert.equal(calls.length, 1);
});
