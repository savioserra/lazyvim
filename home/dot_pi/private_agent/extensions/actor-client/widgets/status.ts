import { Text } from "@earendil-works/pi-tui";
import type { RenderSnapshot } from "../projections/types.ts";

export function renderActorStatusWidget(snapshot: RenderSnapshot, theme: any) {
  const line = snapshot.pendingLine ? `${snapshot.statusLine ?? "actors"} · ${snapshot.pendingLine}` : snapshot.statusLine ?? "";
  const color = snapshot.connection === "connected" ? "success" : snapshot.connection === "degraded" ? "warning" : "dim";
  return new Text(line ? theme.fg(color, line) : "", 0, 0);
}
