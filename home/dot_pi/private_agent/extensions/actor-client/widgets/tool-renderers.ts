import { Text } from "@earendil-works/pi-tui";
import { renderActorClientConversationEnvelope } from "./conversation-card.ts";
import { envelopeFromLegacy } from "../projections/render-envelope.ts";
import { sanitizeText } from "../projections/sanitize.ts";

export function compactToolCall(name: string, args: any): string {
  const target = sanitizeText(args?.target ?? args?.agentId ?? "actor", 48);
  if (/actor_tell/.test(name)) return `↗ Asking ${target}…`;
  if (/send/.test(name)) return `↑ Sending to ${target}…`;
  if (/list/.test(name)) return "List actors";
  if (/resolve|status|health/.test(name)) return `Check ${target}`;
  if (/create/.test(name)) return `Create ${target}`;
  if (/stop|shutdown|abort/.test(name)) return `Control ${target}`;
  return sanitizeText(name.replaceAll("_", " "), 72);
}

export function compactToolResult(name: string, details: any): string {
  const view = details?.renderEnvelope?.renderSnapshot?.card ?? details?.communicationView;
  if (view?.state === "replied") return `✓ ${view.peerDisplayName ?? details?.target ?? "Actor"} replied`;
  if (view?.state === "failed" || details?.accepted === false) return `! Couldn’t reach ${view?.peerDisplayName ?? details?.target ?? "actor"}`;
  if (/actor_tell/.test(name)) return details?.awaitingReply ? `◌ Waiting for ${details?.target ?? "actor"}…` : "✓ request accepted";
  if (/send/.test(name)) return details?.accepted ? "✓ delivered" : "! delivery failed";
  if (Array.isArray(details)) return details.map((item) => `${item.displayName ?? item.agentId ?? "Actor"} ${item.lifecycle ?? "available"}`).join("\n") || "No actors";
  return details?.completed === false ? "Waiting" : "Done";
}

export function modelResultContent(name: string, details: any): string {
  const parts = [`${compactToolResult(name, details)}.`];
  for (const field of ["requestId", "dedupeId", "chainId", "sourceMutationSequence", "kind", "source", "target", "terminal", "nextAction"] as const) if (details?.[field] !== undefined && details[field] !== "") parts.push(`${field}=${sanitizeText(String(details[field]), 128)}`);
  if (details?.completed !== undefined) parts.push(`completed=${details.completed ? "true" : "false"}`);
  if (details?.reason) parts.push(`reason=${sanitizeText(details.reason, 120)}`);
  if (typeof details?.answer === "string" && details.answer) parts.push(`fullAnswer:\n${details.answer}`);
  return parts.join(" ");
}

export function naturalResultSummary(name: string, details: any): string { return sanitizeText(compactToolResult(name, details), 160); }

export function renderToolCall(name: string, args: any, theme: any) { return new Text(theme.fg(/tell/.test(name) ? "accent" : "toolTitle", compactToolCall(name, args)), 0, 0); }

export function renderToolResult(name: string, result: any, options: { isPartial?: boolean; expanded?: boolean }, theme: any) {
  if (options.isPartial) return new Text(theme.fg("warning", "Waiting…"), 0, 0);
  const details = result?.details ?? result;
  if (details?.renderEnvelope) return options.expanded ? renderActorClientConversationEnvelope(details.renderEnvelope, theme) : new Text(theme.fg("toolOutput", compactToolResult(name, details)), 0, 0);
  if (details?.communicationView) return options.expanded ? renderActorClientConversationEnvelope(envelopeFromLegacy({ communicationView: details.communicationView }), theme) : new Text(theme.fg("toolOutput", compactToolResult(name, details)), 0, 0);
  if (options.expanded) return new Text(theme.fg(result?.isError ? "error" : "toolOutput", modelResultContent(name, details)), 0, 0);
  return new Text(theme.fg(result?.isError ? "error" : "toolOutput", compactToolResult(name, details)), 0, 0);
}
