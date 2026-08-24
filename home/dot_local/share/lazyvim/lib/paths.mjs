import path from "node:path";
import { platform } from "./platform.mjs";
import { versions } from "./versions.mjs";

export const targetHome =
  process.env.CHEZMOI_DESTDIR || process.env.HOME || process.env.USERPROFILE;
if (!targetHome)
  throw new Error("Unable to determine the target home directory");

export const localDirectory = path.join(targetHome, ".local");
export const managedNodeExecutable = platform.isWindows
  ? path.join(localDirectory, "opt", "nvm-windows", "nodejs", "node.exe")
  : path.join(
      localDirectory,
      "opt",
      "nvm",
      "versions",
      "node",
      `v${versions.node}`,
      "bin",
      "node",
    );
export const managedNeovimExecutable = platform.isWindows
  ? path.join(localDirectory, "opt", "nvim", "bin", "nvim.exe")
  : path.join(localDirectory, "bin", "nvim");

export function managedToolExecutable(name) {
  return path.join(
    localDirectory,
    "bin",
    `${name}${platform.isWindows ? ".exe" : ""}`,
  );
}
