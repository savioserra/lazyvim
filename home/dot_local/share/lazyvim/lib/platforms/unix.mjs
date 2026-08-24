import fs from "node:fs";
import path from "node:path";
import { localDirectory, targetHome } from "../paths.mjs";
import { versions } from "../versions.mjs";

export function configureNodeHost() {
  const aliasDirectory = path.join(localDirectory, "opt", "nvm", "alias");
  fs.mkdirSync(aliasDirectory, { recursive: true });
  fs.writeFileSync(path.join(aliasDirectory, "default"), `${versions.node}\n`);
}

export function configureUnixRuntimeEnvironment() {
  process.env.PATH = `${path.dirname(managedNodeExecutable)}:${path.join(localDirectory, "bin")}:${process.env.PATH || ""}`;
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

export function verifyNodeHost() {
  const defaultAlias = fs
    .readFileSync(
      path.join(localDirectory, "opt", "nvm", "alias", "default"),
      "utf8",
    )
    .trim();
  if (defaultAlias !== versions.node) {
    throw new Error(
      `Expected nvm default ${versions.node}, got ${defaultAlias}`,
    );
  }
}
