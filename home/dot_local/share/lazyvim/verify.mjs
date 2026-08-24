import fs from "node:fs";
import path from "node:path";
import { captureCommandOutput } from "./lib/commands.mjs";
import { targetHome } from "./lib/paths.mjs";
import {
  managedNeovimExecutable,
  managedNodeExecutable,
  managedToolExecutable,
  neovimDataDirectory,
  platformName,
  verifyHostIntegration,
} from "./lib/platforms/runtime.mjs";
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
  requireOutputPrefix(
    captureCommandOutput(managedToolExecutable("go"), ["version"]),
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
  const pluginLock = JSON.parse(
    fs.readFileSync(path.join(configDirectory, "lazy-lock.json"), "utf8"),
  );
  for (const pluginName of Object.keys(pluginLock)) {
    requireCondition(
      fs.existsSync(path.join(neovimDataDirectory, "lazy", pluginName)),
      `Missing Neovim plugin: ${pluginName}`,
    );
  }
  const masonLock = JSON.parse(
    fs.readFileSync(path.join(configDirectory, "mason-lock.json"), "utf8"),
  );
  for (const packageName of Object.keys(masonLock)) {
    requireCondition(
      fs.existsSync(
        path.join(neovimDataDirectory, "mason", "packages", packageName),
      ),
      `Missing Mason package: ${packageName}`,
    );
  }
}

verifyManagedToolVersions();
verifyNeovimDependencies();
verifyHostIntegration();

console.log(`Verified complete ${platformName} environment.`);
