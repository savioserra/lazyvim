import fs from "node:fs";
import path from "node:path";
import { localDirectory, targetHome } from "../paths.mjs";
import { synchronizeTmuxPlugins, verifyTmuxConfiguration } from "../tmux.mjs";
import { versions } from "../versions.mjs";

export function configureUnixHost() {
  const aliasDirectory = path.join(localDirectory, "opt", "nvm", "alias");
  fs.mkdirSync(aliasDirectory, { recursive: true });
  fs.writeFileSync(path.join(aliasDirectory, "default"), `${versions.node}\n`);
  synchronizeTmuxPlugins();
}

export function configureUnixRuntimeEnvironment() {
  process.env.XDG_DATA_HOME ||= path.join(localDirectory, "share");
  process.env.XDG_STATE_HOME ||= path.join(localDirectory, "state");
  process.env.XDG_CACHE_HOME ||= path.join(targetHome, ".cache");
}

export const managedNodeExecutable = path.join(
  localDirectory,
  "opt",
  "nvm",
  "versions",
  "node",
  `v${versions.node}`,
  "bin",
  "node",
);
export const managedNeovimExecutable = path.join(localDirectory, "bin", "nvim");
export const neovimDataDirectory = path.join(localDirectory, "share", "nvim");

export function managedToolExecutable(name) {
  return path.join(localDirectory, "bin", name);
}

export function verifyUnixHostIntegration() {
  verifyTmuxConfiguration();
}
