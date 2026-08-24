import fs from "node:fs";
import path from "node:path";
import { NODE_VERSION, TMUX_PLUGINS } from "./lib/constants.mjs";
import { output, run } from "./lib/process.mjs";
import {
  home,
  isWindows,
  managedNode,
  managedNvim,
  tool,
} from "./lib/paths.mjs";

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function assertStartsWith(actual, expected, description) {
  assert(
    actual.startsWith(expected),
    `${description}: expected ${expected}, got ${actual}`,
  );
}

assert(
  output(managedNvim, ["--version"]).split(/\r?\n/)[0] === "NVIM v0.12.4",
  "Unexpected Neovim version",
);
assertStartsWith(
  output(
    isWindows
      ? path.join(home, ".local", "opt", "go", "bin", "go.exe")
      : tool("go"),
    ["version"],
  ),
  "go version go1.27.0",
  "Go version",
);
assert(
  output(managedNode, ["--version"]) === `v${NODE_VERSION}`,
  "Unexpected Node.js version",
);
assertStartsWith(
  output(tool("rg"), ["--version"]),
  "ripgrep 15.2.0",
  "ripgrep version",
);
assertStartsWith(output(tool("fd"), ["--version"]), "fd 10.", "fd version");
assertStartsWith(output(tool("fzf"), ["--version"]), "0.74.2", "fzf version");
assert(
  output(tool("lazygit"), ["--version"]).includes("version=0.63.1"),
  "Unexpected lazygit version",
);
assert(
  output(tool("tree-sitter"), ["--version"]).includes("0.26.11"),
  "Unexpected tree-sitter version",
);

const configDirectory = path.join(home, ".config", "nvim");
const dataDirectory = isWindows
  ? path.join(
      process.env.LOCALAPPDATA || path.join(home, "AppData", "Local"),
      "nvim-data",
    )
  : path.join(home, ".local", "share", "nvim");
const lazyLock = JSON.parse(
  fs.readFileSync(path.join(configDirectory, "lazy-lock.json"), "utf8"),
);
for (const plugin of Object.keys(lazyLock)) {
  assert(
    fs.existsSync(path.join(dataDirectory, "lazy", plugin)),
    `Missing Neovim plugin: ${plugin}`,
  );
}
const masonLock = JSON.parse(
  fs.readFileSync(path.join(configDirectory, "mason-lock.json"), "utf8"),
);
for (const packageName of Object.keys(masonLock)) {
  assert(
    fs.existsSync(path.join(dataDirectory, "mason", "packages", packageName)),
    `Missing Mason package: ${packageName}`,
  );
}

if (isWindows) {
  assert(
    output(path.join(home, ".local", "opt", "nvm-windows", "nvm.exe"), [
      "version",
    ]) === "1.2.2",
    "Unexpected nvm-windows version",
  );
  const fontDirectory = path.join(
    home,
    "AppData",
    "Local",
    "Microsoft",
    "Windows",
    "Fonts",
    "JetBrainsMonoNerdFont",
  );
  const fonts = fs
    .readdirSync(fontDirectory)
    .filter((name) => name.endsWith(".ttf"));
  assert(fonts.length > 0, "No JetBrainsMono Nerd Font files were installed");
  const registry = output("reg.exe", [
    "query",
    "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts",
  ]);
  const registered = registry
    .split(/\r?\n/)
    .filter((line) => line.toLowerCase().includes(fontDirectory.toLowerCase()));
  assert(
    registered.length === fonts.length,
    `Expected ${fonts.length} registered fonts, got ${registered.length}`,
  );
} else {
  for (const [name, , commit] of TMUX_PLUGINS) {
    const actual = output("git", [
      "-C",
      path.join(home, ".tmux", "plugins", name),
      "rev-parse",
      "HEAD",
    ]);
    assert(actual === commit, `${name}: expected ${commit}, got ${actual}`);
  }
  try {
    run("tmux", [
      "-L",
      "ci",
      "-f",
      path.join(home, ".tmux.conf"),
      "new-session",
      "-d",
      "-s",
      "ci",
    ]);
    assert(
      output("tmux", ["-L", "ci", "display-message", "-p", "#S"]) === "ci",
      "tmux session did not start",
    );
    assert(
      output("tmux", ["-L", "ci", "show-options", "-gqv", "@tmux2k-theme"]) ===
        "catppuccin",
      "tmux2k theme was not loaded",
    );
  } finally {
    try {
      run("tmux", ["-L", "ci", "kill-server"]);
    } catch {
      // The server may already have exited after a failed assertion.
    }
  }
}

console.log(`Verified complete ${process.platform} environment.`);
