import {
  ASYNC_SNAPSHOT_KIND,
  ASYNC_SNAPSHOT_VERSION,
  MAX_CHILDREN,
  MAX_DEPTH,
  MAX_PROJECTION_BYTES,
  MAX_RUNS,
  MAX_TEXT,
  PROJECTION_SCHEMA_VERSION,
} from "./constants.ts";

export type RunState = "queued" | "running" | "complete" | "failed" | "paused" | "stopped" | "rejected";

export interface ProjectionNode {
  id: string;
  kind: "subagent" | "workflow" | "step";
  label: string;
  state: RunState;
  currentTool?: string;
  role?: string;
  accessMode?: string;
  productivePhase?: string;
  fullscreenTranscript?: boolean;
  updatedAt?: number;
  children?: ProjectionNode[];
}

export interface Projection {
  schemaVersion: 1;
  generatedAt: number;
  source: "pi-subagents-rpc";
  omitted: { runs: number; children: number; sourceByteLimitExceeded: boolean; projectionByteLimitExceeded: boolean };
  runs: ProjectionNode[];
}

const states = new Set<RunState>(["queued", "running", "complete", "failed", "paused", "stopped", "rejected"]);
const kinds = new Set(["subagent", "workflow", "step"]);

function record(value: unknown, label: string): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be an object`);
  return value as Record<string, unknown>;
}

export function sanitizeText(value: unknown, fallback = "", limit = MAX_TEXT): string {
  if (typeof value !== "string") return fallback;
  return value
    .replace(/\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))/g, "")
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/g, "")
    .replace(/[\u202a-\u202e\u2066-\u2069]/g, "")
    .replace(/[\r\n\t]+/g, " ")
    .trim()
    .slice(0, limit) || fallback;
}

function safeTime(value: unknown): number | undefined {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : undefined;
}

function decodeNode(value: unknown, depth: number, omitted: Projection["omitted"]): ProjectionNode {
  const input = record(value, "snapshot node");
  const id = sanitizeText(input.id, "unknown", 128);
  const label = sanitizeText(input.label, "agent");
  if (!kinds.has(input.kind as string)) throw new Error(`snapshot node ${id} has invalid kind`);
  if (!states.has(input.state as RunState)) throw new Error(`snapshot node ${id} has invalid state`);
  const activity = input.activity === undefined ? undefined : record(input.activity, "snapshot activity");
  const node: ProjectionNode = {
    id,
    kind: input.kind as ProjectionNode["kind"],
    label,
    state: input.state as RunState,
  };
  const currentTool = sanitizeText(activity?.currentTool);
  if (currentTool) node.currentTool = currentTool;
  const role = sanitizeText(input.role, "", 64);
  if (role) node.role = role;
  const accessMode = sanitizeText(input.accessMode ?? input.access_mode, "", 32);
  if (accessMode) node.accessMode = accessMode;
  const productivePhase = sanitizeText(input.productivePhase ?? input.productive_phase, "", 32);
  if (productivePhase) node.productivePhase = productivePhase;
  if (input.fullscreenTranscript === true || input.fullscreen_transcript === true) node.fullscreenTranscript = true;
  const updatedAt = safeTime(input.updatedAt) ?? safeTime(activity?.lastActivityAt);
  if (updatedAt !== undefined) node.updatedAt = updatedAt;
  if (Array.isArray(input.children)) {
    if (depth >= MAX_DEPTH) {
      omitted.children += input.children.length;
    } else {
      const selected = input.children.slice(0, MAX_CHILDREN);
      omitted.children += Math.max(0, input.children.length - selected.length);
      node.children = selected.map((child) => decodeNode(child, depth + 1, omitted));
    }
  }
  return node;
}

export function decodeAsyncSnapshot(value: unknown, now = Date.now()): Projection {
  const input = record(value, "async snapshot");
  if (input.kind !== ASYNC_SNAPSHOT_KIND || input.version !== ASYNC_SNAPSHOT_VERSION) {
    throw new Error(`unsupported async snapshot ${String(input.kind)} v${String(input.version)}`);
  }
  if (!Array.isArray(input.runs)) throw new Error("async snapshot runs must be a list");
  const sourceOmitted = record(input.omitted, "async snapshot omitted");
  const selected = input.runs.slice(0, MAX_RUNS);
  const omitted: Projection["omitted"] = {
    runs: Math.max(0, input.runs.length - selected.length) + (Number.isSafeInteger(sourceOmitted.runs) ? Number(sourceOmitted.runs) : 0),
    children: Number.isSafeInteger(sourceOmitted.children) ? Number(sourceOmitted.children) : 0,
    sourceByteLimitExceeded: sourceOmitted.byteLimitExceeded === true,
    projectionByteLimitExceeded: false,
  };
  const projection: Projection = {
    schemaVersion: PROJECTION_SCHEMA_VERSION,
    generatedAt: safeTime(input.generatedAt) ?? now,
    source: "pi-subagents-rpc",
    omitted,
    runs: selected.map((run) => decodeNode(run, 0, omitted)),
  };
  while (Buffer.byteLength(JSON.stringify(projection), "utf8") > MAX_PROJECTION_BYTES && projection.runs.length > 0) {
    projection.runs.pop();
    projection.omitted.runs += 1;
    projection.omitted.projectionByteLimitExceeded = true;
  }
  if (Buffer.byteLength(JSON.stringify(projection), "utf8") > MAX_PROJECTION_BYTES) {
    throw new Error("bounded projection exceeds hard byte limit");
  }
  return projection;
}

function renderNode(node: ProjectionNode, depth: number, lines: string[]): void {
  const marker = node.state === "running" ? "●" : node.state === "complete" ? "✓" : node.state === "failed" ? "✗" : "○";
  const role = node.role ? ` · ${node.role}` : "";
  const access = node.accessMode ? ` · ${node.accessMode}` : "";
  const tool = node.currentTool ? ` · ${node.currentTool}` : "";
  lines.push(`${"  ".repeat(depth)}${marker} ${node.label}${role}${access} · ${node.state}${tool}`);
  for (const child of node.children ?? []) renderNode(child, depth + 1, lines);
}

function findNode(node: ProjectionNode, id: string): ProjectionNode | undefined {
  if (node.id === id) return node;
  for (const child of node.children ?? []) {
    const found = findNode(child, id);
    if (found) return found;
  }
  return undefined;
}

export function scopeProjection(projection: Projection, runId: string, childId?: string): Projection {
  if (!runId) throw new Error("run id is required");
  const run = projection.runs.find((candidate) => candidate.id === runId);
  if (!run) throw new Error(`managed run ${runId} is not visible in the current Pi session`);
  if (!childId) return { ...projection, runs: [run] };
  const child = findNode(run, childId);
  if (!child || child === run) throw new Error(`managed child ${childId} does not belong to run ${runId}`);
  return { ...projection, runs: [{ ...run, children: [child] }] };
}

export function renderProjectionText(projection: Projection): string {
  const lines = ["tmux subagents", `updated ${new Date(projection.generatedAt).toISOString()}`, ""];
  if (projection.runs.length === 0) lines.push("No current-session subagent runs.");
  for (const run of projection.runs) renderNode(run, 0, lines);
  const omitted = projection.omitted.runs + projection.omitted.children;
  if (omitted > 0 || projection.omitted.sourceByteLimitExceeded || projection.omitted.projectionByteLimitExceeded) {
    lines.push("", `… ${omitted} bounded item(s) omitted`);
  }
  lines.push("", "q/Ctrl-C: close view (the managed run continues)");
  return lines.join("\n") + "\n";
}
