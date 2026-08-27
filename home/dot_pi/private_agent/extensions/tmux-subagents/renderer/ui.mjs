import terminalKit from "terminal-kit";
const terminal = terminalKit.terminal;

export class RendererUi {
  constructor(send, exit) { this.send = send; this.exit = exit; this.selected = 0; this.delivery = "connecting"; this.supervisors = {}; this.prompting = false; }
  rows() {
    const rows = []; const visit = (runId, node, depth, root) => { rows.push({ identity: root ? { runId } : { runId, childId: node.id }, node, depth }); for (const child of node.children ?? []) visit(runId, child, depth + 1, false); };
    for (const run of this.projection?.runs ?? []) visit(run.id, run, 0, true); return rows;
  }
  identity() { return this.rows()[this.selected]?.identity; }
  update(frame) {
    if (frame.type === "authenticated") this.delivery = "authenticated; waiting for full snapshot";
    else if (frame.type === "snapshot") { this.projection = frame.projection; this.delivery = frame.delivery?.message ?? "snapshot refreshed"; this.supervisors = frame.supervisors ?? {}; }
    else if (frame.type === "result") this.delivery = `${frame.ok ? "ack" : "error"}: ${String(frame.message)}`;
    else if (frame.type === "fatal") { this.delivery = `blocked: ${String(frame.message)}`; this.render(); setTimeout(() => this.exit(69), 1200); return; }
    this.render();
  }
  render() {
    const width = Math.max(20, terminal.width || 80); const height = Math.max(8, terminal.height || 24); const rows = this.rows(); this.selected = Math.min(this.selected, Math.max(0, rows.length - 1));
    terminal.clear(); terminal.moveTo(1, 1); terminal.bold.cyan("tmux subagents"); terminal("  XState actors / pi-subagents authority\n");
    terminal.dim(); terminal.noFormat(`delivery: ${this.delivery.slice(0, width - 12)}\n`); terminal.styleReset();
    terminal.dim(); terminal.noFormat(`supervisors: ${(Object.entries(this.supervisors).map(([key, value]) => `${key}:${value}`).join(" ") || "healthy").slice(0, width - 14)}\n\n`); terminal.styleReset();
    if (!rows.length) terminal("No current-session runs. Press r to refresh.\n");
    for (let index = 0; index < Math.min(rows.length, height - 8); index++) {
      const row = rows[index]; const marker = row.node.state === "running" ? "●" : row.node.state === "complete" ? "✓" : row.node.state === "failed" ? "✗" : "○";
      const text = `${"  ".repeat(row.depth)}${marker} ${row.node.label} · ${row.node.state}${row.node.currentTool ? ` · ${row.node.currentTool}` : ""}`.slice(0, width - 3);
      if (index === this.selected) { terminal.inverse(); terminal.noFormat(` ${text.padEnd(width - 2)} `); terminal.styleReset(); terminal("\n"); }
      else terminal.noFormat(` ${text}\n`);
    }
    terminal.moveTo(1, height - 2); terminal.dim("arrows select/parent/child  r refresh  s steer  i interrupt  x stop  u resume"); terminal.moveTo(1, height - 1); terminal.dim("q detach (run continues)");
  }
  dispatch(intent) { try { this.send(intent); this.delivery = `${intent.kind} sent; awaiting acknowledgement`; } catch (error) { this.delivery = error.message; } this.render(); }
  prompt(label, callback) { if (this.prompting) return; this.prompting = true; terminal.moveTo(1, Math.max(1, terminal.height - 3)); terminal.eraseLine(); terminal.bold(`${label}: `); terminal.inputField({ maxLength: 4000, cancelable: true }, (error, input) => { this.prompting = false; if (!error && typeof input === "string" && input.trim()) callback(input.trim()); else this.render(); }); }
  confirm(label, callback) { if (this.prompting) return; this.prompting = true; terminal.moveTo(1, Math.max(1, terminal.height - 3)); terminal.eraseLine(); terminal.bold(`${label}? [y/N] `); terminal.yesOrNo({ yes: ["y", "Y"], no: ["n", "N", "ENTER"] }, (error, result) => { this.prompting = false; if (!error && result) callback(); else this.render(); }); }
  start() {
    terminal.fullscreen(true); terminal.grabInput({ mouse: false }); terminal.hideCursor(); this.render();
    terminal.on("key", (name) => {
      if (this.prompting) return;
      if (["CTRL_C", "q", "Q"].includes(name)) { this.dispatch({ kind: "detach" }); this.exit(0); }
      else if (name === "UP") { this.selected = Math.max(0, this.selected - 1); this.dispatch({ kind: "select", direction: "previous", identity: this.identity() }); }
      else if (name === "DOWN") { this.selected = Math.min(Math.max(0, this.rows().length - 1), this.selected + 1); this.dispatch({ kind: "select", direction: "next", identity: this.identity() }); }
      else if (name === "LEFT") { const rows = this.rows(); const depth = rows[this.selected]?.depth ?? 0; for (let index = this.selected - 1; index >= 0; index--) if (rows[index].depth === depth - 1) { this.selected = index; break; } this.dispatch({ kind: "select", direction: "parent", identity: this.identity() }); }
      else if (name === "RIGHT") { const rows = this.rows(); if ((rows[this.selected + 1]?.depth ?? -1) > (rows[this.selected]?.depth ?? 0)) this.selected += 1; this.dispatch({ kind: "select", direction: "child", identity: this.identity() }); }
      else if (["r", "R"].includes(name)) this.dispatch({ kind: "refresh" });
      else if (["s", "S"].includes(name)) this.prompt("steer", (text) => this.dispatch({ kind: "steer", text, identity: this.identity() }));
      else if (["i", "I"].includes(name)) this.confirm("interrupt selected agent", () => this.dispatch({ kind: "interrupt", confirmed: true, identity: this.identity() }));
      else if (["x", "X"].includes(name)) this.confirm("stop selected agent", () => this.dispatch({ kind: "stop", confirmed: true, identity: this.identity() }));
      else if (["u", "U"].includes(name)) this.prompt("resume instruction", (text) => this.confirm("resume exact selected identity", () => this.dispatch({ kind: "resume", confirmed: true, text, identity: this.identity() })));
    });
  }
  stop() { try { terminal.grabInput(false); terminal.hideCursor(false); terminal.styleReset(); terminal.clear(); } catch {} }
}
