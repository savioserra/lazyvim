import { lstat, readFile, readdir, realpath } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ACTOR_PROTOCOL_VERSION } from "../protocol/actor-events.ts";

export interface RuntimeConfig {
  enabled: boolean;
  xstateVersion: string;
  terminalKitVersion: string;
  actorProtocolVersion: number;
}

export interface RuntimeAttestation {
  root: string;
  rendererPath: string;
  nodePath: string;
  xstateVersion: string;
  terminalKitVersion: string;
}

export interface RuntimeOptions { root?: string; platform?: NodeJS.Platform; }

async function regularOwned(file: string, executable: boolean): Promise<void> {
  if (!path.isAbsolute(file) || await realpath(file) !== file) throw new Error(`${file} is not a canonical runtime path`);
  const metadata = await lstat(file);
  if (!metadata.isFile() || metadata.isSymbolicLink()) throw new Error(`${file} is not a regular runtime file`);
  if (typeof process.getuid === "function" && metadata.uid !== process.getuid()) throw new Error(`${file} has foreign ownership`);
  if ((metadata.mode & 0o002) !== 0 || ((metadata.mode & 0o020) !== 0 && (typeof process.getgid !== "function" || metadata.gid !== process.getgid()))) throw new Error(`${file} is writable by another principal`);
  if (executable && (metadata.mode & 0o100) === 0) throw new Error(`${file} is not owner executable`);
}

async function manifestVersion(root: string, name: string): Promise<string> {
  const manifestPath = path.join(root, "node_modules", name, "package.json");
  await regularOwned(manifestPath, false);
  const manifest = JSON.parse(await readFile(manifestPath, "utf8")) as Record<string, unknown>;
  if (typeof manifest.version !== "string") throw new Error(`${name} package manifest has no version`);
  return manifest.version;
}

async function auditDependencyTree(directory: string): Promise<void> {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const item = path.join(directory, entry.name);
    if (entry.isSymbolicLink()) throw new Error(`renderer dependency contains symlink ${item}`);
    if (entry.isDirectory()) await auditDependencyTree(item);
    else if (entry.name.endsWith(".node")) throw new Error(`renderer dependency contains native module ${item}`);
    else if (entry.name === "package.json") {
      const manifest = JSON.parse(await readFile(item, "utf8")) as { scripts?: Record<string, unknown> };
      for (const lifecycle of ["preinstall", "install", "postinstall"]) if (typeof manifest.scripts?.[lifecycle] === "string") {
        throw new Error(`renderer dependency contains lifecycle script ${lifecycle} in ${item}`);
      }
    }
  }
}

export async function attestRuntime(config: RuntimeConfig, options: RuntimeOptions = {}): Promise<RuntimeAttestation> {
  if (!config.enabled) throw new Error("Terminal Kit renderer runtime is disabled; install locked dependencies, enable it, apply, and reload");
  if ((options.platform ?? process.platform) === "win32") throw new Error("tmux-subagents renderer is unavailable on Windows");
  if (config.actorProtocolVersion !== ACTOR_PROTOCOL_VERSION) throw new Error("renderer actor protocol is incompatible");
  const root = options.root ?? path.dirname(fileURLToPath(new URL("../index.ts", import.meta.url)));
  const rendererPath = path.join(root, "renderer", "main.mjs");
  const nodePath = process.execPath;
  await regularOwned(nodePath, true);
  await regularOwned(rendererPath, true);
  const xstateVersion = await manifestVersion(root, "xstate");
  const terminalKitVersion = await manifestVersion(root, "terminal-kit");
  if (xstateVersion !== config.xstateVersion) throw new Error(`installed XState ${xstateVersion} does not match ${config.xstateVersion}`);
  if (terminalKitVersion !== config.terminalKitVersion) throw new Error(`installed Terminal Kit ${terminalKitVersion} does not match ${config.terminalKitVersion}`);
  await auditDependencyTree(path.join(root, "node_modules"));
  return { root, rendererPath, nodePath, xstateVersion, terminalKitVersion };
}
