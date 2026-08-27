import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { createHash } from "node:crypto";
import { lstat, readFile, realpath } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { attestRuntime, type RuntimeConfig } from "./adapters/runtime-attestation.ts";
import { closeView, disposeSystem, focusView, initializeSystem, installedPiSubagentsVersion, openView, refreshSystem, systemSessionId, type ActiveSystem } from "./actors/system.ts";
import { CONFIG_SCHEMA_VERSION } from "./domain/constants.ts";
import { runSmoke } from "./smoke/index.ts";

export interface ExtensionConfig {
  schemaVersion: number; extensionVersion: string; enabled: boolean; compatiblePiSubagentsVersion: string;
  rpcTimeoutMs: number; ticketTtlMs: number; projectionIntervalMs: number; runtime: RuntimeConfig;
}
export interface ExtensionDependencies {
  loadConfig?: () => Promise<ExtensionConfig>;
  attestRuntime?: typeof attestRuntime;
  runSmoke?: typeof runSmoke;
  installedPiSubagentsVersion?: () => Promise<string | undefined>;
  now?: () => number;
  privateRoot?: () => string;
}
const extensionRoot = path.dirname(fileURLToPath(import.meta.url));
function object(value: unknown, label: string): Record<string, unknown> { if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be an object`); return value as Record<string, unknown>; }

export async function loadConfig(): Promise<ExtensionConfig> {
  const configPath = path.join(extensionRoot, "config.json");
  const contents = await readFile(configPath, "utf8");
  const input = object(JSON.parse(contents), "tmux-subagents canonical managed config"); const runtime = object(input.runtime, "tmux-subagents runtime config");
  if (input.schemaVersion !== CONFIG_SCHEMA_VERSION || typeof input.extensionVersion !== "string" || typeof input.enabled !== "boolean" || typeof input.compatiblePiSubagentsVersion !== "string" ||
    typeof input.rpcTimeoutMs !== "number" || input.rpcTimeoutMs < 100 || input.rpcTimeoutMs > 30_000 || typeof input.ticketTtlMs !== "number" || input.ticketTtlMs < 1_000 || input.ticketTtlMs > 15 * 60_000 ||
    typeof input.projectionIntervalMs !== "number" || input.projectionIntervalMs < 250 || input.projectionIntervalMs > 30_000 || typeof runtime.enabled !== "boolean" || typeof runtime.xstateVersion !== "string" || typeof runtime.terminalKitVersion !== "string" || runtime.actorProtocolVersion !== 1) {
    throw new Error("tmux-subagents config is incompatible");
  }
  const config = input as unknown as ExtensionConfig;
  if (config.enabled) {
    const activationPath = path.join(extensionRoot, "activation.json");
    const metadata = await lstat(activationPath);
    if (!metadata.isFile() || metadata.isSymbolicLink() || (typeof process.getuid === "function" && metadata.uid !== process.getuid()) || (metadata.mode & 0o022) !== 0 || await realpath(activationPath) !== activationPath) throw new Error("tmux-subagents activation attestation is unsafe");
    const activation = object(JSON.parse(await readFile(activationPath, "utf8")), "tmux-subagents apply activation attestation");
    const digest = createHash("sha256").update(contents).digest("hex");
    if (activation.schemaVersion !== 1 || activation.configSha256 !== digest) throw new Error("tmux-subagents config was not attested by the latest managed apply");
  }
  if (process.env.PI_TMUX_SUBAGENTS_DISABLE === "1") config.enabled = false; return config;
}
async function doctorRuntime(config: ExtensionConfig, attestor: typeof attestRuntime): Promise<string> {
  try { const runtime = await attestor(config.runtime); return `ok: ${runtime.rendererPath}`; } catch (error) { return `blocked: ${error instanceof Error ? error.message : String(error)}`; }
}

export function createTmuxSubagentsExtension(dependencies: ExtensionDependencies = {}) {
  return function tmuxSubagentsExtension(pi: ExtensionAPI): void {
    let state: ActiveSystem | undefined; let config: ExtensionConfig | undefined; let configFailure: Error | undefined;
    const readConfig = dependencies.loadConfig ?? (() => loadConfig()); const attestor = dependencies.attestRuntime ?? attestRuntime;
    pi.on("session_start", async (_event, ctx) => {
      await disposeSystem(state); state = undefined;
      try {
        config = await readConfig(); configFailure = undefined;
        if (config.enabled) state = await initializeSystem(pi, ctx, config, { attestRuntime: () => attestor(config!.runtime), installedPiSubagentsVersion: dependencies.installedPiSubagentsVersion, now: dependencies.now, privateRoot: dependencies.privateRoot });
      } catch (error) { configFailure = error instanceof Error ? error : new Error(String(error)); ctx.ui.notify(`tmux-subagents disabled: ${configFailure.message}`, "warning"); }
    });
    pi.on("session_shutdown", async () => { await disposeSystem(state); state = undefined; });
    pi.registerCommand("tmux-subagents", {
      description: "Doctor, open, attach, control, refresh, smoke, or reload tmux subagent actors",
      handler: async (argumentsText, ctx) => {
        const [action = "doctor", runId, childId] = argumentsText.trim().split(/\s+/); config = config ?? await readConfig();
        if (action === "reload") { await ctx.reload(); return; }
        if (action === "doctor") {
          const version = await (dependencies.installedPiSubagentsVersion ?? installedPiSubagentsVersion)();
          const lines = [`extension: ${configFailure ? `failed: ${configFailure.message}` : `loaded ${config.extensionVersion}`}`, `feature: ${config.enabled ? "enabled" : "disabled"}`, `pi-subagents: ${version ?? "missing"} (expected ${config.compatiblePiSubagentsVersion})`, `tmux: ${process.env.TMUX ? "available" : "outside tmux"}`, `XState/Terminal Kit runtime: ${await doctorRuntime(config, attestor)}`];
          ctx.ui.notify(lines.join("\n"), lines.some((line) => line.includes("blocked") || line.includes("failed")) ? "warning" : "info"); return;
        }
        if (action === "smoke") {
          if (!config.enabled || !state) throw new Error(`tmux-subagents smoke blocked: ${configFailure?.message ?? "enable the feature, apply, reload, and start one trivial async run"}`);
          ctx.ui.notify(await (dependencies.runSmoke ?? runSmoke)({ rpc: state.rpc, attestation: state.runtime, ownerPiSessionId: systemSessionId(ctx), generation: state.generation }), "info"); return;
        }
        if (!config.enabled || !state) throw new Error("tmux-subagents is disabled or unattested; enable locked renderer config, apply, and reload first");
        if (action === "refresh") { refreshSystem(state); ctx.ui.notify("tmux-subagents authority refresh requested", "info"); return; }
        if (action === "focus" && runId) { await focusView(state, runId); return; }
        if (action === "close" && runId) { await closeView(state, runId); ctx.ui.notify(`closed view ${runId}; managed run unchanged`, "info"); return; }
        if ((action === "prepare" || action === "open") && runId) { ctx.ui.notify(await openView(state, ctx, runId, childId, action === "open", config.ticketTtlMs), "info"); return; }
        throw new Error("usage: /tmux-subagents doctor|prepare <run-id> [child-id]|open <run-id> [child-id]|focus <binding-id>|close <binding-id>|refresh|smoke|reload");
      },
    });
  };
}
export default createTmuxSubagentsExtension();
