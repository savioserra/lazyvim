import { Box, Container, Text } from "@earendil-works/pi-tui";

export type CommunicationDirection = "incoming" | "outgoing";
export type CommunicationIntent = "note" | "request" | "reply" | "control" | "failure";
export type CommunicationState = "pending" | "delivered" | "replied" | "failed";
export type CommunicationPeer = { stableId?: string; stable_id?: string; displayName?: string; display_name?: string; role?: string };

export type CommunicationView = {
  key: string;
  direction: CommunicationDirection;
  intent: CommunicationIntent;
  state: CommunicationState;
  peerDisplayName: string;
  peerRole: string;
  body: string;
  reply?: string;
  durationMillis?: number;
};

const SENSITIVE = /\b(?:raw[-_ ]*)?(principal|session|credential|pid|handle|fence|runtime)(?:[-_:=]?[A-Za-z0-9_.:/-]*)?/gi;
const MAX_BODY_PREVIEW = 480;
const MAX_TOOL_PREVIEW = 160;

export function safePreview(value: Uint8Array | string | undefined, max = 240): string {
  const text = typeof value === "string" ? value : value ? new TextDecoder("utf-8", { fatal: false }).decode(value) : "";
  const clean = text
    .replace(/[\r\t\x00]/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .replace(SENSITIVE, "[redacted]")
    .trim();
  return clean.length > max ? `${clean.slice(0, Math.max(0, max - 1))}…` : clean;
}

function semantic(theme: any, preferred: string, fallback: string, text: string): string { try { return theme.fg(preferred, text); } catch { return theme.fg(fallback, text); } }

export function peerView(peer?: CommunicationPeer | string): { displayName: string; role: string } {
  if (typeof peer === "string") return { displayName: safePreview(peer || "Unknown actor", 48), role: "" };
  return {
    displayName: safePreview(peer?.displayName ?? peer?.display_name ?? "Unknown actor", 48),
    role: naturalRole(peer?.role),
  };
}

function naturalRole(value?: string): string {
  const clean = safePreview(value ?? "", 32);
  if (!clean) return "";
  return clean === clean.toLocaleUpperCase() ? clean.toLocaleLowerCase().replaceAll("_", " ") : clean;
}

export function incomingNote(key: string, source: CommunicationPeer | undefined, body: Uint8Array | string): CommunicationView {
  const peer = peerView(source);
  return { key, direction: "incoming", intent: "note", state: "delivered", peerDisplayName: peer.displayName, peerRole: peer.role, body: safePreview(body, MAX_BODY_PREVIEW) };
}

export function incomingRequest(key: string, source: CommunicationPeer | undefined, body: Uint8Array | string): CommunicationView {
  const peer = peerView(source);
  return { key, direction: "incoming", intent: "request", state: "pending", peerDisplayName: peer.displayName, peerRole: peer.role, body: safePreview(body, MAX_BODY_PREVIEW) };
}

export function incomingControl(key: string, source: CommunicationPeer | undefined, action: string): CommunicationView {
  const peer = peerView(source);
  return { key, direction: "incoming", intent: "control", state: "delivered", peerDisplayName: peer.displayName, peerRole: peer.role, body: safePreview(action, MAX_BODY_PREVIEW) };
}

export function outgoingExchange(input: {
  key: string;
  target?: CommunicationPeer | string;
  body: string;
  reply?: string;
  accepted: boolean;
  completed?: boolean;
  mode: "tell" | "ask";
  reason?: string;
  durationMillis?: number;
}): CommunicationView {
  const peer = peerView(input.target);
  if (!input.accepted) return { key: input.key, direction: "outgoing", intent: "failure", state: "failed", peerDisplayName: peer.displayName, peerRole: peer.role, body: safePreview(input.reason || "The message could not be delivered.", MAX_BODY_PREVIEW), durationMillis: input.durationMillis };
  if (input.mode === "ask") return { key: input.key, direction: "outgoing", intent: "request", state: input.completed === false ? "pending" : "replied", peerDisplayName: peer.displayName, peerRole: peer.role, body: safePreview(input.body, MAX_BODY_PREVIEW), reply: safePreview(input.reply, MAX_BODY_PREVIEW), durationMillis: input.durationMillis };
  return { key: input.key, direction: "outgoing", intent: "note", state: "delivered", peerDisplayName: peer.displayName, peerRole: peer.role, body: safePreview(input.body, MAX_BODY_PREVIEW), durationMillis: input.durationMillis };
}

export function incomingRequestText(delivery: { source?: CommunicationPeer; boundedPayload: Uint8Array }): string {
  const peer = peerView(delivery.source);
  const role = peer.role ? ` · ${peer.role}` : "";
  return `**${peer.displayName}${role} asked you**\n\n${safePreview(delivery.boundedPayload, 16 * 1024)}`;
}

// bridgeDiagnostic is the bounded, payload-free diagnostic card for the
// bridge's own lifecycle surfaces (prompt finish path, acknowledgement
// outcomes, replay handling). It carries only identifiers, sequences,
// outcomes, and coarse error classes.
export function bridgeDiagnostic(input: { key: string; line: string; failed?: boolean }): CommunicationView {
  return { key: input.key, direction: "outgoing", intent: input.failed ? "failure" : "control", state: input.failed ? "failed" : "delivered", peerDisplayName: "Hosted bridge", peerRole: "bridge", body: safePreview(input.line, 200) };
}

export function communicationTitle(view: CommunicationView): string {
  const role = view.peerRole ? ` · ${view.peerRole}` : "";
  if (view.intent === "failure") return `Couldn’t reach ${view.peerDisplayName}${role}`;
  if (view.direction === "incoming" && view.intent === "control") return `Incoming control from ${view.peerDisplayName}${role}`;
  if (view.direction === "incoming" && view.intent === "request") return `${view.peerDisplayName}${role} asked you`;
  if (view.direction === "incoming") return `${view.peerDisplayName}${role} sent a note`;
  if (view.intent === "request") return `Asked ${view.peerDisplayName}${role}`;
  return `Sent to ${view.peerDisplayName}${role}`;
}

export function communicationFooter(view: CommunicationView): string {
  const duration = view.durationMillis !== undefined && view.durationMillis >= 0 ? ` in ${formatDuration(view.durationMillis)}` : "";
  if (view.state === "pending") return `◌ Waiting for ${view.peerDisplayName}…`;
  if (view.state === "failed") return "retry available";
  if (view.state === "replied") return `✓ replied${duration}`;
  return `✓ delivered`;
}

export function renderCommunicationCard(view: CommunicationView, theme: any) {
  const bg = view.direction === "incoming" ? "customMessageBg" : view.state === "failed" ? "toolErrorBg" : view.state === "pending" ? "toolPendingBg" : "toolSuccessBg";
  const titleColor = view.state === "failed" ? "error" : view.direction === "incoming" ? "accent" : view.intent === "request" ? "magenta" : "blue";
  const icon = view.state === "failed" ? "!" : view.direction === "incoming" ? "↓" : view.intent === "request" ? "↗" : "↑";
  const box = new Box(1, 1, (text: string) => theme.bg(bg, text));
  const title = `${icon} ${communicationTitle(view)}`;
  const styledTitle = titleColor === "magenta" ? semantic(theme, "magenta", "accent", theme.bold ? theme.bold(title) : title) : titleColor === "blue" ? semantic(theme, "blue", "toolTitle", theme.bold ? theme.bold(title) : title) : theme.fg(titleColor, theme.bold ? theme.bold(title) : title);
  box.addChild(new Text(styledTitle, 0, 0));
  if (view.body) box.addChild(new Text(view.body, 0, 0));
  if (view.reply) {
    box.addChild(new Text("", 0, 0));
    box.addChild(new Text(theme.fg("success", `↙ ${view.peerDisplayName} replied`), 0, 0));
    box.addChild(new Text(view.reply, 0, 0));
  }
  box.addChild(new Text(theme.fg("dim", communicationFooter(view)), 0, 0));
  return box;
}

export function compactToolCall(name: string, args: any): string {
  const target = safePreview(args?.target ?? args?.agentId ?? "", 48);
  const prompt = safePreview(args?.message ?? args?.prompt ?? "", 72);
  if (/ask/.test(name)) return `Ask ${target || "actor"}${prompt ? `: ${prompt}` : ""}`;
  if (/tell|send/.test(name)) return `Tell ${target || "actor"}${prompt ? `: ${prompt}` : ""}`;
  if (/list/.test(name)) return "List actors";
  if (/resolve|status/.test(name)) return `Check ${target || "actor"}`;
  if (/create/.test(name)) return `Create ${target || "actor"}`;
  if (/stop|shutdown|abort/.test(name)) return `Stop ${target || "actor"}`;
  if (/subscribe/.test(name)) return `Subscribe to ${target || "actor"}`;
  return safePreview(name.replaceAll("_", " "), 72);
}

export function compactToolResult(name: string, details: any): string {
  if (Array.isArray(details)) return details.map((item) => actorStatusLine(item)).join("\n") || "No actors";
  if (details?.accepted === false || (details?.reason && details?.accepted !== true)) return `! ${safePreview(details.reason || "request failed", 120)}`;
  if (/send/.test(name)) return details?.accepted ? "Delivered" : "Delivery failed";
  if (/ask/.test(name)) return details?.accepted ? (details?.completed ? "Completed" : "Admitted") : "Delivery failed";
  if (/tell/.test(name)) return details?.accepted ? "Delivered" : "Delivery failed";
  if (/resolve/.test(name)) return actorStatusLine(details?.agent ? { displayName: details.displayName ?? details.agent, role: details.role, state: 3 } : details);
  if (/health|status/.test(name)) return details?.reachable === true ? actorStatusLine(details?.agent ? { displayName: details.displayName ?? details.agent, role: details.role, state: 3 } : details) : actorStatusLine(details);
  return details?.completed === false ? "Waiting" : "Done";
}

export function renderToolCall(name: string, args: any, theme: any) {
  const target = safePreview(args?.target ?? args?.agentId ?? "actor", 48);
  if (/ask/.test(name)) return new Text(theme.fg("accent", `↗ Asking ${target}…`), 0, 0);
  if (/tell/.test(name)) return new Text(theme.fg("accent", `↑ Sending to ${target}…`), 0, 0);
  if (/send/.test(name)) return new Text(theme.fg("toolTitle", `↑ Sending to ${target}…`), 0, 0);
  return new Text(theme.fg("toolTitle", compactToolCall(name, args)), 0, 0);
}

export function renderToolResult(name: string, result: any, options: { isPartial?: boolean; expanded?: boolean }, theme: any) {
  if (options.isPartial) return new Text(theme.fg("warning", compactToolCall(name, result?.details ?? {})), 0, 0);
  if (options.expanded && fullModelAnswer(result?.details) !== undefined) return renderFullAnswerResult(name, result.details, theme);
  if (result?.details?.communicationView) {
    if (options.expanded) return renderCommunicationCard(result.details.communicationView, theme);
    const view = result.details.communicationView;
    const peer = view.peerDisplayName;
    const line = view.state === "replied" ? `✓ ${peer} replied` : view.state === "failed" ? `! Couldn’t reach ${peer}` : /ask/.test(name) && view.state === "pending" ? `◌ Waiting for ${peer}…` : `✓ delivered`;
    return new Text(theme.fg(view.state === "failed" ? "error" : view.state === "pending" ? "warning" : "success", line), 0, 0);
  }
  return new Text(theme.fg(result?.isError ? "error" : "toolOutput", compactToolResult(name, result?.details)), 0, 0);
}

export function naturalResultSummary(name: string, details: any): string {
  return safePreview(compactToolResult(name, details), MAX_TOOL_PREVIEW);
}

export function modelResultContent(name: string, details: any): string {
  const summary = naturalResultSummary(name, details);
  if (/actor_tell|actor_ask/.test(name) && details) {
    const parts = [`${summary}.`];
    for (const field of ["requestId", "dedupeId", "chainId", "sourceMutationSequence", "kind", "source", "target"] as const) {
      if (details[field] !== undefined && details[field] !== "") parts.push(`${field}=${safePreview(String(details[field]), 128)}`);
    }
    if (details.completed !== undefined) parts.push(`completed=${details.completed ? "true" : "false"}`);
    if (details.reason) parts.push(`reason=${safePreview(details.reason, 120)}`);
    const answer = fullModelAnswer(details);
    if (answer !== undefined) parts.push(`fullAnswer:\n${answer}`);
    return parts.join(" ");
  }
  return summary;
}

function fullModelAnswer(details: any): string | undefined {
  const value = details?.answer ?? details?.result;
  return typeof value === "string" && value.length > 0 ? value : undefined;
}

function renderFullAnswerResult(name: string, details: any, theme: any) {
  const answer = fullModelAnswer(details) ?? "";
  const header = theme.fg("success", compactToolResult(name, details));
  const meta: string[] = [];
  for (const field of ["lifecycleId", "requestId", "targetDisplayName", "target", "state", "terminal"] as const) {
    if (details?.[field] !== undefined && details[field] !== "") meta.push(`${field}=${safePreview(String(details[field]), 128)}`);
  }
  const body = [header, ...meta.map((line) => theme.fg("dim", line)), "", answer].join("\n");
  return new Text(body, 0, 0);
}

function actorStatusLine(actor: any): string {
  const name = safePreview(actor?.displayName ?? actor?.agent ?? actor?.agentId ?? "Actor", 48);
  const roleText = naturalRole(actor?.role);
  const role = roleText ? ` · ${roleText}` : "";
  const state = actor?.accepted === false ? "unavailable" : actor?.bridgeReady === false ? "reconnecting" : Number(actor?.state) === 3 || Number(actor?.runtimeState) === 3 ? "ready" : Number(actor?.state) === 4 || Number(actor?.runtimeState) === 4 ? "degraded" : "available";
  const icon = state === "ready" || state === "available" ? "●" : state === "reconnecting" ? "◌" : "!";
  return `${icon} ${name}${role} — ${state}`;
}

function label(theme: any, value: string): string { return theme.fg("muted", `${value}:`); }
function formatDuration(milliseconds: number): string { return milliseconds < 1000 ? `${Math.max(1, Math.round(milliseconds))}ms` : `${Math.round(milliseconds / 1000)}s`; }

export function legacyCommunicationLine(view: CommunicationView): string {
  return safePreview(`${communicationTitle(view)} — ${view.body}${view.reply ? ` — Reply: ${view.reply}` : ""}`, 160);
}
