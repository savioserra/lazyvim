import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chmod, mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { loadConfig } from "../../home/dot_pi/private_agent/extensions/tmux-subagents/index.ts";

test("production config ignores arbitrary environment overrides and requires its managed activation digest", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "tmux-subagents-config-"));
  const contents = await readFile("home/dot_pi/private_agent/extensions/tmux-subagents/config.json", "utf8");
  await writeFile(path.join(root, "config.json"), contents, { mode: 0o600 });
  await writeFile(path.join(root, "activation.json"), `${JSON.stringify({ schemaVersion: 1, configSha256: createHash("sha256").update(contents).digest("hex") })}\n`, { mode: 0o600 });
  await chmod(path.join(root, "activation.json"), 0o600);
  const previous = process.env.PI_TMUX_SUBAGENTS_CONFIG_PATH;
  process.env.PI_TMUX_SUBAGENTS_CONFIG_PATH = "/tmp/unreviewed-enabled-config.json";
  try { assert.equal((await loadConfig(root)).enabled, true); }
  finally {
    if (previous === undefined) delete process.env.PI_TMUX_SUBAGENTS_CONFIG_PATH;
    else process.env.PI_TMUX_SUBAGENTS_CONFIG_PATH = previous;
  }
});
