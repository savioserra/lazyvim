import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
  buildNotification,
  extractAssistantText,
  loadConfig,
  publishNtfy,
} from "../src/ntfy.js";

function latestRunState(ctx: ExtensionContext) {
  const branch = ctx.sessionManager.getBranch();
  for (let index = branch.length - 1; index >= 0; index -= 1) {
    const entry = branch[index];
    if (entry.type !== "message" || entry.message.role !== "assistant") continue;

    const trailingToolResults = branch.slice(index + 1).filter(
      (candidate) => candidate.type === "message" && candidate.message.role === "toolResult",
    );
    return {
      assistant: entry.message,
      hasToolError: trailingToolResults.some(
        (candidate) => candidate.type === "message" && candidate.message.role === "toolResult" && candidate.message.isError,
      ),
    };
  }
  return { assistant: undefined, hasToolError: false };
}

function reportFailure(error: unknown, ctx: ExtensionContext): void {
  const message = error instanceof Error ? error.message : String(error);
  console.error(`[pi-ntfy-notifier] ${message}`);
  if (ctx.hasUI) ctx.ui.notify(`ntfy notification failed: ${message}`, "warning");
}

export default function ntfyNotifier(pi: ExtensionAPI) {
  let runStartedAt: number | undefined;

  pi.on("agent_start", () => {
    runStartedAt ??= Date.now();
  });

  pi.on("agent_settled", async (_event, ctx) => {
    if (runStartedAt === undefined) return;

    const startedAt = runStartedAt;
    runStartedAt = undefined;
    const config = loadConfig();
    if (!config.enabled) return;

    const { assistant, hasToolError } = latestRunState(ctx);
    const notification = buildNotification({
      assistantText: extractAssistantText(assistant),
      stopReason: assistant?.stopReason,
      hasToolError,
      durationMs: Date.now() - startedAt,
      cwd: ctx.cwd,
      sessionName: ctx.sessionManager.getSessionName(),
      includeContext: config.includeContext,
    });

    try {
      await publishNtfy(config, notification);
    } catch (error) {
      reportFailure(error, ctx);
    }
  });

  pi.on("session_shutdown", () => {
    runStartedAt = undefined;
  });

  pi.registerCommand("ntfy-test", {
    description: "Send a test ntfy notification (usage: /ntfy-test [complete|action])",
    handler: async (args, ctx) => {
      const requestedKind = args.trim().toLowerCase();
      const forceKind = requestedKind === "action" ? "action" : "complete";
      const config = loadConfig();
      if (!config.enabled) {
        if (ctx.hasUI) {
          ctx.ui.notify("ntfy notifier is unconfigured: set PI_NTFY_SERVER and PI_NTFY_TOPIC", "warning");
        }
        return;
      }

      const notification = buildNotification({
        durationMs: 0,
        cwd: ctx.cwd,
        sessionName: ctx.sessionManager.getSessionName(),
        includeContext: config.includeContext,
        forceKind,
      });
      notification.body = `Test notification. ${notification.body}`;

      try {
        await publishNtfy(config, notification);
        if (ctx.hasUI) ctx.ui.notify(`ntfy test sent to ${config.server}/${config.topic}`, "info");
      } catch (error) {
        reportFailure(error, ctx);
      }
    },
  });

  pi.registerCommand("ntfy-status", {
    description: "Show the active ntfy notifier configuration",
    handler: async (_args, ctx) => {
      const config = loadConfig();
      const status = config.enabled ? "enabled" : "disabled";
      const auth = config.token ? "token configured" : "no token";
      if (ctx.hasUI) {
        ctx.ui.notify(
          `ntfy ${status}: ${config.server}/${config.topic} (${auth}, context ${config.includeContext ? "on" : "off"})`,
          "info",
        );
      }
    },
  });
}
