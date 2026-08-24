import path from "node:path";
import { NODE_VERSION } from "./constants.mjs";

export const isWindows = process.platform === "win32";
export const isLinux = process.platform === "linux";
export const home =
  process.env.CHEZMOI_DESTDIR || process.env.HOME || process.env.USERPROFILE;

if (!home) throw new Error("Unable to determine the target home directory");

export const local = path.join(home, ".local");
export const managedNode = isWindows
  ? path.join(local, "opt", "nvm-windows", "nodejs", "node.exe")
  : path.join(
      local,
      "opt",
      "nvm",
      "versions",
      "node",
      `v${NODE_VERSION}`,
      "bin",
      "node",
    );
export const managedNvim = isWindows
  ? path.join(local, "opt", "nvim", "bin", "nvim.exe")
  : path.join(local, "bin", "nvim");

export function tool(name) {
  return path.join(local, "bin", `${name}${isWindows ? ".exe" : ""}`);
}
