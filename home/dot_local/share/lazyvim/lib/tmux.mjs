import fs from "node:fs";
import path from "node:path";
import { captureCommandOutput, executeCommand } from "./commands.mjs";
import { targetHome } from "./paths.mjs";

export const tmuxPlugins = Object.freeze([
  [
    "tpm",
    "https://github.com/tmux-plugins/tpm.git",
    "e261deb1b47614eed3400089ce7197dc68acc4eb",
  ],
  [
    "tmux2k",
    "https://github.com/2KAbhishek/tmux2k.git",
    "07b3228b56c1a7b6109f00009df80b53f7eae892",
  ],
  [
    "tmux-yank",
    "https://github.com/tmux-plugins/tmux-yank.git",
    "acfd36e4fcba99f8310a7dfb432111c242fe7392",
  ],
  [
    "vim-tmux-navigator",
    "https://github.com/christoomey/vim-tmux-navigator.git",
    "e41c431a0c7b7388ae7ba341f01a0d217eb3a432",
  ],
  [
    "tmux-resurrect",
    "https://github.com/tmux-plugins/tmux-resurrect.git",
    "cff343cf9e81983d3da0c8562b01616f12e8d548",
  ],
]);

function tmuxPluginDirectory(name) {
  return path.join(targetHome, ".tmux", "plugins", name);
}

export function synchronizeTmuxPlugins() {
  const pluginsDirectory = path.join(targetHome, ".tmux", "plugins");
  fs.mkdirSync(pluginsDirectory, { recursive: true });
  fs.rmSync(path.join(pluginsDirectory, "tmux-fingers"), {
    recursive: true,
    force: true,
  });

  for (const [name, repository, commit] of tmuxPlugins) {
    const checkoutDirectory = tmuxPluginDirectory(name);
    if (!fs.existsSync(path.join(checkoutDirectory, ".git"))) {
      executeCommand("git", [
        "clone",
        "--quiet",
        repository,
        checkoutDirectory,
      ]);
    }
    try {
      executeCommand("git", [
        "-C",
        checkoutDirectory,
        "fetch",
        "--quiet",
        "origin",
        commit,
      ]);
    } catch {
      // An already-present commit remains usable during a temporary network failure.
    }
    executeCommand("git", [
      "-C",
      checkoutDirectory,
      "checkout",
      "--quiet",
      commit,
    ]);
  }
}

export function verifyTmuxConfiguration() {
  for (const [name, , expectedCommit] of tmuxPlugins) {
    const actualCommit = captureCommandOutput("git", [
      "-C",
      tmuxPluginDirectory(name),
      "rev-parse",
      "HEAD",
    ]);
    if (actualCommit !== expectedCommit) {
      throw new Error(
        `${name}: expected ${expectedCommit}, got ${actualCommit}`,
      );
    }
  }

  try {
    executeCommand("tmux", [
      "-L",
      "ci",
      "-f",
      path.join(targetHome, ".tmux.conf"),
      "new-session",
      "-d",
      "-s",
      "ci",
    ]);
    if (
      captureCommandOutput("tmux", [
        "-L",
        "ci",
        "display-message",
        "-p",
        "#S",
      ]) !== "ci"
    ) {
      throw new Error("tmux session did not start");
    }
    if (
      captureCommandOutput("tmux", [
        "-L",
        "ci",
        "show-options",
        "-gqv",
        "@tmux2k-theme",
      ]) !== "catppuccin"
    ) {
      throw new Error("tmux2k theme was not loaded");
    }
  } finally {
    try {
      executeCommand("tmux", ["-L", "ci", "kill-server"]);
    } catch {
      // The server may already have exited after a failed assertion.
    }
  }
}
