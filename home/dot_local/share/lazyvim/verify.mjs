import fs from "node:fs";
import path from "node:path";
import { captureCommandOutput } from "./lib/commands.mjs";
import { windowsFontDirectory } from "./lib/fonts.mjs";
import {
  managedNeovimExecutable,
  managedNodeExecutable,
  managedToolExecutable,
  targetHome,
} from "./lib/paths.mjs";
import { platform } from "./lib/platform.mjs";
import { verifyTmuxConfiguration } from "./lib/tmux.mjs";
import { versions } from "./lib/versions.mjs";

function requireCondition(condition, failureMessage) {
  if (!condition) throw new Error(failureMessage);
}

function requireOutputPrefix(actualOutput, expectedPrefix, description) {
  requireCondition(
    actualOutput.startsWith(expectedPrefix),
    `${description}: expected ${expectedPrefix}, got ${actualOutput}`,
  );
}

function verifyManagedToolVersions() {
  requireCondition(
    captureCommandOutput(managedNeovimExecutable, ["--version"]).split(
      /\r?\n/,
    )[0] === `NVIM v${versions.neovim}`,
    "Unexpected Neovim version",
  );
  const goExecutable = platform.isWindows
    ? path.join(targetHome, ".local", "opt", "go", "bin", "go.exe")
    : managedToolExecutable("go");
  requireOutputPrefix(
    captureCommandOutput(goExecutable, ["version"]),
    `go version go${versions.go}`,
    "Go version",
  );
  requireCondition(
    captureCommandOutput(managedNodeExecutable, ["--version"]) ===
      `v${versions.node}`,
    "Unexpected Node.js version",
  );
  requireOutputPrefix(
    captureCommandOutput(managedToolExecutable("rg"), ["--version"]),
    `ripgrep ${versions.ripgrep}`,
    "ripgrep version",
  );
  requireOutputPrefix(
    captureCommandOutput(managedToolExecutable("fd"), ["--version"]),
    `fd ${versions.fdMajor}.`,
    "fd version",
  );
  requireOutputPrefix(
    captureCommandOutput(managedToolExecutable("fzf"), ["--version"]),
    versions.fzf,
    "fzf version",
  );
  requireCondition(
    captureCommandOutput(managedToolExecutable("lazygit"), [
      "--version",
    ]).includes(`version=${versions.lazygit}`),
    "Unexpected lazygit version",
  );
  requireCondition(
    captureCommandOutput(managedToolExecutable("tree-sitter"), [
      "--version",
    ]).includes(versions.treeSitter),
    "Unexpected tree-sitter version",
  );
}

function verifyNeovimDependencies() {
  const configDirectory = path.join(targetHome, ".config", "nvim");
  const dataDirectory = platform.isWindows
    ? path.join(
        process.env.LOCALAPPDATA || path.join(targetHome, "AppData", "Local"),
        "nvim-data",
      )
    : path.join(targetHome, ".local", "share", "nvim");
  const pluginLock = JSON.parse(
    fs.readFileSync(path.join(configDirectory, "lazy-lock.json"), "utf8"),
  );
  for (const pluginName of Object.keys(pluginLock)) {
    requireCondition(
      fs.existsSync(path.join(dataDirectory, "lazy", pluginName)),
      `Missing Neovim plugin: ${pluginName}`,
    );
  }
  const masonLock = JSON.parse(
    fs.readFileSync(path.join(configDirectory, "mason-lock.json"), "utf8"),
  );
  for (const packageName of Object.keys(masonLock)) {
    requireCondition(
      fs.existsSync(path.join(dataDirectory, "mason", "packages", packageName)),
      `Missing Mason package: ${packageName}`,
    );
  }
}

function verifyWindowsIntegration() {
  requireCondition(
    captureCommandOutput(
      path.join(targetHome, ".local", "opt", "nvm-windows", "nvm.exe"),
      ["version"],
    ) === versions.nvmWindows,
    "Unexpected nvm-windows version",
  );
  const fontDirectory = windowsFontDirectory();
  const installedFonts = fs
    .readdirSync(fontDirectory)
    .filter((name) => name.endsWith(".ttf"));
  requireCondition(
    installedFonts.length > 0,
    "No JetBrainsMono Nerd Font files were installed",
  );
  const fontRegistry = captureCommandOutput("reg.exe", [
    "query",
    "HKCU\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Fonts",
  ]);
  const registeredFonts = fontRegistry
    .split(/\r?\n/)
    .filter((line) => line.toLowerCase().includes(fontDirectory.toLowerCase()));
  requireCondition(
    registeredFonts.length === installedFonts.length,
    `Expected ${installedFonts.length} registered fonts, got ${registeredFonts.length}`,
  );
}

verifyManagedToolVersions();
verifyNeovimDependencies();
if (platform.isWindows) verifyWindowsIntegration();
else verifyTmuxConfiguration();

console.log(`Verified complete ${platform.name} environment.`);
