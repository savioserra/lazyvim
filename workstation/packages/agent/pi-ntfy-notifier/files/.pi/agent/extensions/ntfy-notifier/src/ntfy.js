import { basename } from "node:path";
import { hostname } from "node:os";

// No default server or topic: publishing is opt-in per host via environment
// configuration, so no infrastructure details are baked into this package.

const FALSE_VALUES = /^(?:0|false|no|off)$/i;
const TRUE_VALUES = /^(?:1|true|yes|on)$/i;
const TOPIC_PATTERN = /^[-_A-Za-z0-9]{1,64}$/;
const REQUEST_VERBS = "provide|choose|select|confirm|approve|answer|clarify|send|share|decide|run|install|open|upload|retry|review|configure|restart|update|enter|supply|grant";
const ACTION_PATTERNS = [
  /\b(?:i|we)\s+need\s+(?:your|user)\s+(?:input|approval|confirmation|decision|choice|answer|permission|action)\b/i,
  /\bi\s+need\s+you\s+to\b/i,
  /\byou\s+need\s+to\b/i,
  new RegExp(`\\b(?:please|kindly)\\s+(?:${REQUEST_VERBS})\\b`, "i"),
  new RegExp(`\\b(?:can|could|would|will)\\s+you\\s+(?:${REQUEST_VERBS})\\b`, "i"),
  /^(?:action|decision|approval|confirmation|input)\s+(?:is\s+)?(?:needed|required)\b/i,
  /\b(?:(?:i am|i'm|we are|we're)\s+blocked|blocked\s+(?:by|on|until|because)|waiting for|cannot continue|can't continue|before i (?:can|continue|proceed)|before we (?:can|continue|proceed))\b/i,
  /\b(?:which|what|where|when|who)\s+(?:option|approach|value|path|file|repository|repo|environment|account|version)\b[^?]*\?\s*$/i,
  /\b(?:do you want|would you like|should i)\b[^?]*\?\s*$/i,
];
const COMPLETION_PATTERNS = [
  /\bno (?:(?:further|user|additional) )?action (?:is )?(?:needed|required)\b/i,
  /\b(?:completed|finished|done|succeeded|successful|passed|fixed|resolved|validated)\b/i,
  /\bready for (?:the )?(?:next task|next step|review|use|deployment)\b/i,
];

function envFlag(value, fallback) {
  if (typeof value !== "string" || value.trim() === "") return fallback;
  if (TRUE_VALUES.test(value.trim())) return true;
  if (FALSE_VALUES.test(value.trim())) return false;
  return fallback;
}

function envInteger(value, fallback, min, max) {
  const parsed = Number.parseInt(value ?? "", 10);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, parsed));
}

export function loadConfig(env = process.env) {
  const server = env.PI_NTFY_SERVER?.trim() || "";
  const topic = env.PI_NTFY_TOPIC?.trim() || "";
  return {
    enabled: Boolean(server && topic),
    server,
    topic,
    token: env.PI_NTFY_TOKEN?.trim() || undefined,
    timeoutMs: envInteger(env.PI_NTFY_TIMEOUT_MS, 5000, 1000, 30000),
    includeContext: envFlag(env.PI_NTFY_INCLUDE_CONTEXT, false),
  };
}

export function extractAssistantText(message) {
  if (!message || message.role !== "assistant" || !Array.isArray(message.content)) return "";
  return message.content
    .filter((block) => block?.type === "text" && typeof block.text === "string")
    .map((block) => block.text)
    .join("\n")
    .trim();
}

function lastMatchIndex(text, patterns) {
  let latest = -1;
  for (const pattern of patterns) {
    const match = pattern.exec(text);
    if (match) latest = Math.max(latest, match.index);
  }
  return latest;
}

export function classifyResult(text, stopReason = "stop", hasToolError = false) {
  if (hasToolError || ["error", "aborted", "length"].includes(stopReason)) return "action";

  const normalized = text.trim();
  if (!normalized) return stopReason === "toolUse" ? "complete" : "action";

  const clauses = normalized
    .split(/(?<=[.!?])(?:\s+|$)|\n+/)
    .map((clause) => clause.trim())
    .filter(Boolean)
    .slice(-4);

  for (let index = clauses.length - 1; index >= 0; index -= 1) {
    const clause = clauses[index];
    if (clause.endsWith("?") && clause.length <= 500) return "action";

    const actionIndex = lastMatchIndex(clause, ACTION_PATTERNS);
    const completionIndex = lastMatchIndex(clause, COMPLETION_PATTERNS);
    if (actionIndex >= 0 || completionIndex >= 0) {
      return actionIndex > completionIndex ? "action" : "complete";
    }
  }

  return "complete";
}

export function formatDuration(durationMs) {
  const totalSeconds = Math.max(0, Math.round(durationMs / 1000));
  if (totalSeconds < 60) return `${totalSeconds}s`;
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  if (minutes < 60) return seconds === 0 ? `${minutes}m` : `${minutes}m ${seconds}s`;
  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;
  return remainingMinutes === 0 ? `${hours}h` : `${hours}h ${remainingMinutes}m`;
}

export function buildNotification({
  assistantText = "",
  stopReason = "stop",
  durationMs = 0,
  cwd = "",
  sessionName,
  includeContext = false,
  forceKind,
  hasToolError = false,
} = {}) {
  const kind = forceKind ?? classifyResult(assistantText, stopReason, hasToolError);
  const isAction = kind === "action";
  const context = sessionName?.trim() || (cwd ? basename(cwd) : "");
  const location = [hostname(), context].filter(Boolean).join(" / ");
  const statusTitle = isAction ? "Pi needs attention" : "Pi completed";
  const title = context ? `${statusTitle} — ${context}` : statusTitle;

  let body = isAction
    ? "Pi is waiting for input or attention."
    : "Pi finished and is ready for the next task.";
  body += ` Duration: ${formatDuration(durationMs)}.`;
  if (includeContext && location) body += ` Context: ${location}.`;

  return {
    kind,
    title,
    body,
    priority: isAction ? "high" : "default",
    tags: isAction ? ["robot", "warning"] : ["robot", "heavy_check_mark"],
  };
}

function buildServerUrl(server) {
  const base = new URL(server);
  if (base.protocol !== "https:" && base.protocol !== "http:") {
    throw new Error("PI_NTFY_SERVER must use http:// or https://");
  }
  const host = base.hostname.replace(/^\[|\]$/g, "").toLowerCase();
  const isLoopback = host === "localhost" || host === "127.0.0.1" || host === "::1";
  if (base.protocol !== "https:" && !isLoopback) {
    throw new Error("PI_NTFY_SERVER requires an https:// URL (http:// is allowed only for localhost)");
  }
  if (!base.pathname.endsWith("/")) base.pathname += "/";
  return base.toString();
}

export function buildTopicUrl(server, topic) {
  if (!TOPIC_PATTERN.test(topic)) {
    throw new Error("PI_NTFY_TOPIC must be 1-64 letters, numbers, underscores, or dashes");
  }
  return new URL(encodeURIComponent(topic), buildServerUrl(server)).toString();
}

export async function publishNtfy(config, notification, fetchImpl = globalThis.fetch) {
  if (typeof fetchImpl !== "function") throw new Error("No fetch implementation is available");
  if (!TOPIC_PATTERN.test(config.topic)) {
    throw new Error("PI_NTFY_TOPIC must be 1-64 letters, numbers, underscores, or dashes");
  }

  const url = buildServerUrl(config.server);
  if (config.token && !/^[\x20-\x7E]+$/.test(config.token)) {
    throw new Error("PI_NTFY_TOKEN must contain printable ASCII characters only");
  }

  // Send metadata in a UTF-8 JSON body instead of HTTP headers. The Fetch
  // Headers API accepts only ByteString values, so Unicode session names (for
  // example the em dash in "Pi completed — agent") otherwise throw before the
  // request can be sent.
  const headers = { "Content-Type": "application/json; charset=utf-8" };
  if (config.token) headers.Authorization = `Bearer ${config.token}`;
  const body = JSON.stringify({
    topic: config.topic,
    title: notification.title,
    message: notification.body,
    priority: notification.priority === "high" ? 4 : 3,
    tags: notification.tags,
  });

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), config.timeoutMs);
  timeout.unref?.();

  try {
    const response = await fetchImpl(url, {
      method: "POST",
      headers,
      body,
      signal: controller.signal,
    });
    if (!response.ok) {
      const responseText = (await response.text()).trim().slice(0, 300);
      throw new Error(`ntfy returned HTTP ${response.status}${responseText ? `: ${responseText}` : ""}`);
    }
    return { url, status: response.status };
  } finally {
    clearTimeout(timeout);
  }
}
