import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { createHash, randomUUID } from "node:crypto";
import { lstat, readFile, realpath } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { attestRuntime, type RuntimeConfig } from "./adapters/runtime-attestation.ts";
import { DiagnosticJournal } from "./adapters/diagnostic-journal.ts";
import { PrivateViewStore } from "./adapters/store.ts";
import { createDiagnosticsActor } from "./actors/diagnostics.ts";
import { closeView, defaultPrivateRoot, disposeSystem, focusView, initializeSystem, installedPiSubagentsVersion, openView, refreshSystem, systemSessionId, type ActiveSystem, type SystemDependencies } from "./actors/system.ts";
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
  createStore?: SystemDependencies["createStore"];
  createDiagnosticJournal?: SystemDependencies["createDiagnosticJournal"];
  createIpcServer?: SystemDependencies["createIpcServer"];
  createRootActor?: SystemDependencies["createRootActor"];
  createProductionSupervisor?: SystemDependencies["createProductionSupervisor"];
}
const extensionRoot = path.dirname(fileURLToPath(import.meta.url));
function object(value: unknown, label: string): Record<string, unknown> { if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be an object`); return value as Record<string, unknown>; }

export async function loadConfig(managedRoot: string = extensionRoot): Promise<ExtensionConfig> {
  const configPath = path.join(managedRoot, "config.json");
  const contents = await readFile(configPath, "utf8");
  const input = object(JSON.parse(contents), "tmux-subagents canonical managed config"); const runtime = object(input.runtime, "tmux-subagents runtime config");
  if (input.schemaVersion !== CONFIG_SCHEMA_VERSION || typeof input.extensionVersion !== "string" || typeof input.enabled !== "boolean" || typeof input.compatiblePiSubagentsVersion !== "string" ||
    typeof input.rpcTimeoutMs !== "number" || input.rpcTimeoutMs < 100 || input.rpcTimeoutMs > 30_000 || typeof input.ticketTtlMs !== "number" || input.ticketTtlMs < 1_000 || input.ticketTtlMs > 15 * 60_000 ||
    typeof input.projectionIntervalMs !== "number" || input.projectionIntervalMs < 250 || input.projectionIntervalMs > 30_000 || typeof runtime.enabled !== "boolean" || typeof runtime.xstateVersion !== "string" || typeof runtime.terminalKitVersion !== "string" || runtime.actorProtocolVersion !== 1) {
    throw new Error("tmux-subagents config is incompatible");
  }
  const config = input as unknown as ExtensionConfig;
  if (config.enabled) {
    const activationPath = path.join(managedRoot, "activation.json");
    const metadata = await lstat(activationPath);
    if (!metadata.isFile() || metadata.isSymbolicLink() || (typeof process.getuid === "function" && metadata.uid !== process.getuid()) || (metadata.mode & 0o022) !== 0 || await realpath(activationPath) !== activationPath) throw new Error("tmux-subagents activation attestation is unsafe");
    const activation = object(JSON.parse(await readFile(activationPath, "utf8")), "tmux-subagents apply activation attestation");
    const digest = createHash("sha256").update(contents).digest("hex");
    if (activation.schemaVersion !== 1 || activation.configSha256 !== digest) throw new Error("tmux-subagents config was not attested by the latest managed apply");
  }
  if (process.env.PI_TMUX_SUBAGENTS_DISABLE === "1") config.enabled = false; return config;
}
async function doctorRuntime(config: ExtensionConfig, attestor: typeof attestRuntime): Promise<string> {
  try { const runtime = await attestor(config.runtime); return `ok: ${runtime.rendererPath}`; } catch { return "blocked; see diagnostics"; }
}

export function tmuxSubagentsClosedMessage(): string { return "closed tmux-subagents view; managed run unchanged"; }

export function createTmuxSubagentsExtension(dependencies: ExtensionDependencies = {}) {
  return function tmuxSubagentsExtension(pi: ExtensionAPI): void {
    let state: ActiveSystem | undefined; let config: ExtensionConfig | undefined; let configFailure: Error | undefined; let bootstrap: { generation: string; store: PrivateViewStore; diagnostics: ReturnType<typeof createDiagnosticsActor> } | undefined;
    const readConfig = dependencies.loadConfig ?? (() => loadConfig()); const attestor = dependencies.attestRuntime ?? attestRuntime;
    const stopBootstrap = async () => { const target = bootstrap; bootstrap = undefined; if (!target) return; const failures: unknown[] = []; try { await target.diagnostics.stop(); } catch (error) { failures.push(error); } try { await target.store.removeOwnedGeneration(); } catch (error) { failures.push(error); } if (failures.length) throw new AggregateError(failures, "bootstrap diagnostics cleanup failed"); };
    const startBootstrap = async (ctx: ExtensionContext) => { const generation = `bootstrap-${randomUUID()}`; const store = new PrivateViewStore(dependencies.privateRoot?.() ?? defaultPrivateRoot(), systemSessionId(ctx), generation); let diagnostics: ReturnType<typeof createDiagnosticsActor> | undefined; try { await store.initialize(); diagnostics = createDiagnosticsActor(new DiagnosticJournal(store.generationRoot, generation)); diagnostics.start(); await diagnostics.record({ type: "DIAGNOSTIC.LIFECYCLE", category: "lifecycle", severity: "info", phase: "bootstrap-ready", status: "success" }); return { generation, store, diagnostics }; } catch (error) { const failures: unknown[] = [error]; if (diagnostics) try { await diagnostics.stop(); } catch (cleanup) { failures.push(cleanup); } try { await store.removeOwnedGeneration(); } catch (cleanup) { failures.push(cleanup); } throw failures.length === 1 ? error : new AggregateError(failures, "bootstrap diagnostics rollback failed"); } };
    pi.on("session_start", async (_event, ctx) => {
      await disposeSystem(state); state = undefined; await stopBootstrap();
      try {
        bootstrap = await startBootstrap(ctx); config = await readConfig(); configFailure = undefined;
        if (config.enabled) { await stopBootstrap(); state = await initializeSystem(pi, ctx, config, { attestRuntime: () => attestor(config!.runtime), installedPiSubagentsVersion: dependencies.installedPiSubagentsVersion, now: dependencies.now, privateRoot: dependencies.privateRoot, createStore: dependencies.createStore, createDiagnosticJournal: dependencies.createDiagnosticJournal, createIpcServer: dependencies.createIpcServer, createRootActor: dependencies.createRootActor, createProductionSupervisor: dependencies.createProductionSupervisor }); }
      } catch (error) {
        configFailure = error instanceof Error ? error : new Error(String(error));
        try { bootstrap ??= await startBootstrap(ctx); await bootstrap.diagnostics.record({ type: "DIAGNOSTIC.LIFECYCLE", category: "lifecycle", severity: "error", phase: "system-initialize", status: "failure", error: configFailure }); } catch {}
        ctx.ui.notify("tmux-subagents disabled; run /tmux-subagents diagnostics 20", "warning");
      }
    });
    pi.on("session_shutdown", async () => { await disposeSystem(state); state = undefined; await stopBootstrap(); });
    pi.registerCommand("tmux-subagents", {
      description: "Doctor, diagnose, open, attach, control, refresh, smoke, or reload tmux subagent actors",
      handler: async (argumentsText, ctx) => {
        const [action = "doctor", runId, childId] = argumentsText.trim().split(/\s+/); const requestId = randomUUID(); const receiptId = `command:${requestId}`; const observer = state?.diagnostics ?? bootstrap?.diagnostics; let failed = false;
        if (!observer) throw new Error("tmux-subagents command blocked: diagnostic persistence is unavailable; no receipt was issued");
        try { await observer.record({ type: "DIAGNOSTIC.COMMAND", category: "command", severity: "info", phase: "command", status: "start", requestId, receiptId, metadata: { action } }); }
        catch { throw new Error("tmux-subagents command blocked: diagnostic persistence failed; no receipt was issued"); }
        try {
          config = config ?? await readConfig();
          if (action === "reload") { await ctx.reload(); return; }
          if (action === "doctor") {
            const version = await (dependencies.installedPiSubagentsVersion ?? installedPiSubagentsVersion)(); const health = observer?.health();
            const lines = [`extension: ${configFailure ? "failed; see diagnostics" : `loaded ${config.extensionVersion}`}`, `feature: ${config.enabled ? "enabled" : "disabled"}`, `pi-subagents: ${version ?? "missing"} (expected ${config.compatiblePiSubagentsVersion})`, `tmux: ${process.env.TMUX ? "available" : "outside tmux"}`, `XState/Terminal Kit runtime: ${await doctorRuntime(config, attestor)}`, `observability: ${health?.state ?? "unavailable"}${health?.latestErrorReceipt ? ` (latest error ${health.latestErrorReceipt})` : ""}`];
            ctx.ui.notify(lines.join("\n"), lines.some((line) => line.includes("blocked") || line.includes("failed") || line.includes("unavailable")) ? "warning" : "info"); return;
          }
          if ((action === "diagnostics" || action === "status") && observer) {
            const requested = Number.parseInt(runId ?? "10", 10); const records = await observer.recent(Number.isFinite(requested) ? requested : 10); const health = observer.health();
            const lines = [`generation: ${state?.generation ?? bootstrap?.generation ?? "unavailable"}`, `observability: ${health.state}${health.latestErrorReceipt ? `; latest error ${health.latestErrorReceipt}` : ""}`, ...records.map((record) => `${new Date(record.timestamp).toISOString()} #${record.sequence} ${record.severity} ${record.category}/${record.phase} ${record.status}${record.receiptId ? ` receipt=${record.receiptId}` : ""}${record.errorMessage ? `: ${record.errorMessage}` : ""}`)];
            ctx.ui.notify(lines.join("\n"), health.state === "healthy" ? "info" : "warning"); return;
          }
          if (action === "smoke") {
            if (!config.enabled || !state) throw new Error(`tmux-subagents smoke blocked: ${configFailure?.message ?? "enable the feature, apply, reload, and start one trivial async run"}`);
            ctx.ui.notify(await (dependencies.runSmoke ?? runSmoke)({ rpc: state.rpc, attestation: state.runtime, ownerPiSessionId: systemSessionId(ctx), generation: state.generation, observe: async (event) => { await state!.diagnostics.record({ type: "DIAGNOSTIC.SMOKE", category: "smoke", severity: event.status === "failure" ? "error" : "info", phase: event.phase, status: event.status, requestId, receiptId, ...(event.error ? { error: event.error } : {}), metadata: event.metadata }); } }), "info"); return;
          }
          if (!config.enabled || !state) throw new Error("tmux-subagents is disabled or unattested; enable locked renderer config, apply, and reload first");
          if (action === "refresh") { refreshSystem(state); ctx.ui.notify("tmux-subagents authority refresh requested", "info"); return; }
          if (action === "focus" && runId) { await focusView(state, runId); return; }
          if (action === "close" && runId) { await closeView(state, runId); ctx.ui.notify(tmuxSubagentsClosedMessage(), "info"); return; }
          if ((action === "prepare" || action === "open") && runId) { ctx.ui.notify(await openView(state, ctx, runId, childId, action === "open", config.ticketTtlMs), "info"); return; }
          throw new Error("usage: /tmux-subagents doctor|diagnostics [count]|prepare <run-id> [child-id]|open <run-id> [child-id]|focus <binding-id>|close <binding-id>|refresh|smoke|reload");
        } catch (error) {
          failed = true; const failure = error instanceof Error ? error : new Error(String(error));
          let persisted; try { persisted = await observer.record({ type: "DIAGNOSTIC.COMMAND", category: "command", severity: "error", phase: "command", status: "failure", requestId, receiptId, error: failure, metadata: { action } }); observer.setLatestErrorReceipt(receiptId); } catch {}
          throw new Error(persisted ? `${persisted.errorMessage ?? "local operation failed"}${persisted.errorCode ? ` (${persisted.errorCode})` : ""} [receipt ${receiptId}]` : "tmux-subagents command failed and diagnostic persistence failed; no durable receipt was issued");
        } finally {
          if (!failed) try { await observer.record({ type: "DIAGNOSTIC.COMMAND", category: "command", severity: "info", phase: "command", status: "success", requestId, receiptId, metadata: { action } }); } catch { throw new Error("tmux-subagents command completed but durable success persistence failed; no success receipt was issued"); }
        }
      },
    });
  };
}
export default createTmuxSubagentsExtension();
