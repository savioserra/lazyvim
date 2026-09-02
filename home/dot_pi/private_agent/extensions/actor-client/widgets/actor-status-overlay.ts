import { Key, matchesKey, truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";
import type { ActorUiSnapshot } from "../projections/types.ts";

export class ActorStatusOverlay {
  private selected = 0;
  private expanded = new Set<string>();
  private cachedWidth?: number;
  private cachedRevision?: number;
  private cachedLines?: string[];
  private readonly getSnapshot: () => ActorUiSnapshot;
  private readonly theme: any;
  private readonly close: () => void;
  constructor(getSnapshot: () => ActorUiSnapshot, theme: any, close: () => void) { this.getSnapshot = getSnapshot; this.theme = theme; this.close = close; }

  handleInput(data: string): void {
    const snapshot = this.getSnapshot();
    if (matchesKey(data, Key.escape) || matchesKey(data, Key.ctrl("c"))) { this.close(); return; }
    if (matchesKey(data, Key.up)) this.selected = Math.max(0, this.selected - 1);
    if (matchesKey(data, Key.down)) this.selected = Math.min(Math.max(0, snapshot.rows.length - 1), this.selected + 1);
    if (matchesKey(data, Key.enter) || matchesKey(data, Key.space)) {
      const row = snapshot.rows[this.selected];
      if (row) this.expanded.has(row.agentId) ? this.expanded.delete(row.agentId) : this.expanded.add(row.agentId);
    }
    this.invalidate();
  }

  render(width: number): string[] {
    const snapshot = this.getSnapshot();
    this.selected = Math.min(this.selected, Math.max(0, snapshot.rows.length - 1));
    if (this.cachedLines && this.cachedWidth === width && this.cachedRevision === snapshot.revision) return this.cachedLines;
    const color = snapshot.connection === "connected" ? "success" : snapshot.connection === "degraded" ? "warning" : "dim";
    const lines: string[] = [];
    lines.push(this.fit(this.theme.fg("accent", "Actor status"), width));
    lines.push(this.fit(this.theme.fg(color, snapshot.footer || "actors unavailable"), width));
    if (width < 25) {
      lines.push(this.fit(snapshot.rows.length ? `actors +${snapshot.rows.length}` : "actors none", width));
      lines.push(this.fit("esc close", width));
      return this.remember(width, snapshot.revision, lines);
    }
    if (!snapshot.rows.length) lines.push(this.fit(this.theme.fg("dim", "No visible actors"), width));
    for (let index = 0; index < snapshot.rows.length; index++) {
      const row = snapshot.rows[index]!;
      const selected = index === this.selected;
      const expanded = this.expanded.has(row.agentId);
      const prefix = selected ? "› " : "  ";
      const marker = expanded ? "▾" : "▸";
      const rowText = `${prefix}${marker} ${row.displayName} · ${row.lifecycle}${row.activity ? ` · ${row.activity}` : ""}${row.pending ? " · pending" : ""}`;
      lines.push(this.fit(selected ? this.theme.bg("selectedBg", rowText) : rowText, width));
      if (expanded) {
        const detail = [row.role ? `role ${row.role}` : undefined, row.activity ? `activity ${row.activity}` : undefined, row.pending ? "request pending" : undefined].filter(Boolean).join(" · ") || "No additional visible status";
        lines.push(this.fit(this.theme.fg("muted", `    ${detail}`), width));
      }
    }
    lines.push(this.fit(this.theme.fg("dim", "↑↓ move • enter/space expand • esc close"), width));
    return this.remember(width, snapshot.revision, lines);
  }

  invalidate(): void { this.cachedWidth = undefined; this.cachedRevision = undefined; this.cachedLines = undefined; }

  private remember(width: number, revision: number, lines: string[]): string[] { this.cachedWidth = width; this.cachedRevision = revision; this.cachedLines = lines; return lines; }
  private fit(text: string, width: number): string { return visibleWidth(text) <= width ? text : truncateToWidth(text, Math.max(1, width)); }
}

export function renderActorStatusFallback(snapshot: ActorUiSnapshot, width = 80): string {
  const limit = Math.max(20, Math.min(120, width));
  const lines = [snapshot.footer || "actors unavailable"];
  for (const row of snapshot.rows) lines.push(`${row.displayName} | ${row.lifecycle}${row.activity ? ` | ${row.activity}` : ""}${row.pending ? " | pending" : ""}`);
  if (!snapshot.rows.length) lines.push("No visible actors");
  return lines.map((line) => truncateToWidth(line.replace(/[\0\r\n\t\u001b\u202a-\u202e\u2066-\u2069]/g, " "), limit)).join("\n");
}
