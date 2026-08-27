import assert from "node:assert/strict";
import test from "node:test";
import { loadConfig } from "../../home/dot_pi/agent/extensions/tmux-subagents/index.ts";

test("production config ignores arbitrary environment overrides and cannot be enabled by a launcher environment", async () => {
  const previous = process.env.PI_TMUX_SUBAGENTS_CONFIG_PATH;
  process.env.PI_TMUX_SUBAGENTS_CONFIG_PATH = "/tmp/unreviewed-enabled-config.json";
  try { assert.equal((await loadConfig()).enabled, false); }
  finally {
    if (previous === undefined) delete process.env.PI_TMUX_SUBAGENTS_CONFIG_PATH;
    else process.env.PI_TMUX_SUBAGENTS_CONFIG_PATH = previous;
  }
});
