import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { PaneIdentity, ViewBinding } from "./store.ts";

const execFileAsync = promisify(execFile);
const paneFormat = "#{pane_id}\t#{pane_pid}\t#{pane_tty}\t#{session_id}";
const mismatch = "__TMUX_SUBAGENTS_IDENTITY_MISMATCH__";
const windowFormat = "#{window_id}\t#{window_panes}\t#{@workstation_tmux_subagents_owner}\t#{session_id}";
const ownedPaneFormat = "#{pane_id}\t#{pane_pid}\t#{pane_tty}\t#{session_id}\t#{@workstation_tmux_subagents_owner}\t#{@workstation_tmux_subagents_pane_id}\t#{@workstation_tmux_subagents_pane_pid}\t#{@workstation_tmux_subagents_pane_tty}\t#{@workstation_tmux_subagents_session_id}";

interface OwnedWindow { windowId: string; panes: number; owner: string; sessionId: string }
interface OwnedPane extends PaneIdentity { owner: string; markedPaneId: string; markedPanePid: number; markedPaneTty: string; markedSessionId: string }

function parseWindows(output: string): OwnedWindow[] {
  if (!output.trim()) return [];
  return output.trim().split("\n").map((line) => {
    const [windowId, panes, owner, sessionId, ...extra] = line.split("\t");
    if (extra.length || !/^@[0-9]+$/.test(windowId) || !/^[1-9][0-9]*$/.test(panes) || !/^\$[0-9]+$/.test(sessionId)) {
      throw new Error("tmux returned incompatible window topology");
    }
    return { windowId, panes: Number(panes), owner, sessionId };
  });
}

function parseOwnedPanes(socketPath: string, output: string): OwnedPane[] {
  if (!output.trim()) return [];
  return output.trim().split("\n").map((line) => {
    const [paneId, panePid, paneTty, sessionId, owner, markedPaneId, markedPanePid, markedPaneTty, markedSessionId, ...extra] = line.split("\t");
    if (extra.length || !/^%[0-9]+$/.test(paneId) || !/^[0-9]+$/.test(panePid) || !paneTty || !/^\$[0-9]+$/.test(sessionId) || !/^[0-9]+$/.test(markedPanePid)) throw new Error("tmux returned incompatible pane ownership");
    return { socketPath, paneId, panePid: Number(panePid), paneTty, sessionId, owner, markedPaneId, markedPanePid: Number(markedPanePid), markedPaneTty, markedSessionId };
  });
}

function exactlyOwned(panes: OwnedPane[], owner: string, expectedCount: number): boolean {
  return panes.length === expectedCount && panes.every((pane) => pane.owner === owner && pane.markedPaneId === pane.paneId && pane.markedPanePid === pane.panePid && pane.markedPaneTty === pane.paneTty && pane.markedSessionId === pane.sessionId);
}

export interface CommandExecutor {
  (file: string, args: readonly string[], options: { timeout: number }): Promise<{ stdout: string; stderr: string }>;
}

function parseIdentity(socketPath: string, output: string): PaneIdentity {
  const [paneId, panePid, paneTty, sessionId, ...extra] = output.trim().split("\t");
  if (extra.length || !/^%[0-9]+$/.test(paneId) || !/^[0-9]+$/.test(panePid) || !paneTty || !/^\$[0-9]+$/.test(sessionId)) {
    throw new Error("tmux returned an incompatible pane identity");
  }
  return { socketPath, paneId, panePid: Number(panePid), paneTty, sessionId };
}

function safeFormatValue(value: string, label: string): string {
  if (!value || /[,{}\n\0]/.test(value)) throw new Error(`${label} cannot be represented safely in a tmux format`);
  return value;
}

function identityCondition(expected: PaneIdentity): string {
  const terms = [
    `#{==:#{pane_id},${safeFormatValue(expected.paneId, "pane id")}}`,
    `#{==:#{pane_pid},${expected.panePid}}`,
    `#{==:#{pane_tty},${safeFormatValue(expected.paneTty, "pane tty")}}`,
    `#{==:#{session_id},${safeFormatValue(expected.sessionId, "session id")}}`,
  ];
  return terms.slice(1).reduce((condition, term) => `#{&&:${condition},${term}}`, terms[0]);
}

export function socketFromTmuxEnvironment(value: string): string {
  const match = /^(.*),[0-9]+,[0-9]+$/.exec(value);
  if (!match?.[1] || match[1].includes("\n") || match[1].includes("\0")) throw new Error("TMUX does not contain a valid server socket");
  return match[1];
}

export class TmuxController {
  readonly socketPath: string;
  private readonly execute: CommandExecutor;

  constructor(
    socketPath: string,
    execute: CommandExecutor = async (file, args, options) => {
      const result = await execFileAsync(file, [...args], { timeout: options.timeout, encoding: "utf8", windowsHide: true });
      return { stdout: result.stdout, stderr: result.stderr };
    },
  ) {
    if (!socketPath || socketPath.includes("\0") || socketPath.includes("\n")) throw new Error("tmux socket path is invalid");
    this.socketPath = socketPath;
    this.execute = execute;
  }

  private async tmux(args: readonly string[]): Promise<string> {
    const result = await this.execute("tmux", ["-S", this.socketPath, ...args], { timeout: 5000 });
    return result.stdout;
  }

  async inspectPane(paneId: string): Promise<PaneIdentity> {
    if (!/^%[0-9]+$/.test(paneId)) throw new Error("tmux pane id is invalid");
    return parseIdentity(this.socketPath, await this.tmux(["display-message", "-p", "-t", paneId, paneFormat]));
  }

  async createPane(cwd: string): Promise<PaneIdentity> {
    if (!cwd || cwd.includes("\0") || cwd.includes("\n")) throw new Error("tmux pane cwd is invalid");
    return parseIdentity(this.socketPath, await this.tmux(["split-window", "-d", "-P", "-F", paneFormat, "-c", cwd]));
  }

  private async markPane(pane: PaneIdentity, owner: string): Promise<void> {
    for (const [name, value] of [["@workstation_tmux_subagents_owner", owner], ["@workstation_tmux_subagents_pane_id", pane.paneId], ["@workstation_tmux_subagents_pane_pid", String(pane.panePid)], ["@workstation_tmux_subagents_pane_tty", pane.paneTty], ["@workstation_tmux_subagents_session_id", pane.sessionId]] as const) await this.tmux(["set-option", "-p", "-t", pane.paneId, name, value]);
  }

  private async ownedPanes(windowId: string): Promise<OwnedPane[]> {
    return parseOwnedPanes(this.socketPath, await this.tmux(["list-panes", "-t", windowId, "-F", ownedPaneFormat]));
  }

  async openOwnedPane(input: { cwd: string; command: string; owner: string; windowName?: string; maxPanesPerWindow?: number; maxWindows?: number }): Promise<PaneIdentity> {
    if (!input.cwd || /[\0\n]/.test(input.cwd)) throw new Error("tmux pane cwd is invalid");
    if (!input.command || /[\0\n]/.test(input.command)) throw new Error("tmux pane command is invalid");
    if (!/^[A-Za-z0-9._:@+-]{1,160}$/.test(input.owner)) throw new Error("tmux topology owner is invalid");
    const maxPanes = input.maxPanesPerWindow ?? 4; const maxWindows = input.maxWindows ?? 4;
    if (!Number.isInteger(maxPanes) || maxPanes < 1 || maxPanes > 12 || !Number.isInteger(maxWindows) || maxWindows < 1 || maxWindows > 12) {
      throw new Error("tmux topology limits are invalid");
    }
    const owned = parseWindows(await this.tmux(["list-windows", "-F", windowFormat])).filter((window) => window.owner === input.owner);
    const candidates = owned.sort((left, right) => left.windowId.localeCompare(right.windowId, undefined, { numeric: true })).filter((window) => window.panes < maxPanes);
    for (const reusable of candidates) {
      if (!exactlyOwned(await this.ownedPanes(reusable.windowId), input.owner, reusable.panes)) continue;
      const pane = parseIdentity(this.socketPath, await this.tmux(["split-window", "-d", "-P", "-F", paneFormat, "-t", reusable.windowId, "-c", input.cwd, input.command]));
      try {
        await this.markPane(pane, input.owner);
        if (!exactlyOwned(await this.ownedPanes(reusable.windowId), input.owner, reusable.panes + 1)) {
          await this.conditionalAction(pane, "kill").catch(() => {});
          continue;
        }
        await this.tmux(["select-layout", "-t", reusable.windowId, "tiled"]);
        return pane;
      } catch (error) { await this.conditionalAction(pane, "kill").catch(() => {}); throw error; }
    }
    if (owned.length >= maxWindows) throw new Error(`tmux-subagents topology overflow: ${maxWindows} owned windows at ${maxPanes} panes each`);
    const name = `${input.windowName ?? "subagents"}-${owned.length + 1}`;
    if (!/^[A-Za-z0-9._+-]{1,60}$/.test(name)) throw new Error("tmux window name is invalid");
    const pane = parseIdentity(this.socketPath, await this.tmux(["new-window", "-d", "-P", "-F", paneFormat, "-n", name, "-c", input.cwd, input.command]));
    try {
      const windowId = (await this.tmux(["display-message", "-p", "-t", pane.paneId, "#{window_id}"])).trim();
      if (!/^@[0-9]+$/.test(windowId)) throw new Error("tmux returned an invalid created window identity");
      await this.tmux(["set-option", "-w", "-t", windowId, "@workstation_tmux_subagents_owner", input.owner]);
      await this.markPane(pane, input.owner);
    } catch (error) { await this.conditionalAction(pane, "kill").catch(() => {}); throw error; }
    return pane;
  }

  private async conditionalAction(expected: PaneIdentity, action: "focus" | "kill"): Promise<void> {
    if (expected.socketPath !== this.socketPath) throw new Error("pane belongs to another tmux server");
    const command = action === "focus" ? `select-window -t ${expected.paneId} ; select-pane -t ${expected.paneId}` : `kill-pane -t ${expected.paneId}`;
    const output = await this.tmux([
      "if-shell", "-F", "-t", expected.paneId, identityCondition(expected), command, `display-message -p ${mismatch}`,
    ]);
    if (output.includes(mismatch)) throw new Error("tmux pane identity changed before action");
  }

  async focusPane(expected: PaneIdentity): Promise<void> {
    await this.conditionalAction(expected, "focus");
  }

  async closeCreated(binding: ViewBinding): Promise<void> {
    if (!binding.created) throw new Error("refusing to close an adopted tmux pane");
    await this.conditionalAction(binding.pane, "kill");
  }
}

export function assertSamePane(actual: PaneIdentity, expected: PaneIdentity): void {
  for (const field of ["socketPath", "paneId", "panePid", "paneTty", "sessionId"] as const) {
    if (actual[field] !== expected[field]) throw new Error(`tmux pane identity changed at ${field}`);
  }
}
