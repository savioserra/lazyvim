import path from "node:path";
import { captureCommandOutput, executeCommand } from "../commands.mjs";
import { localDirectory } from "../paths.mjs";
import {
  configureNodeHost,
  configureUnixRuntimeEnvironment,
  managedNeovimExecutable,
  managedNodeExecutable,
  managedToolExecutable,
  neovimDataDirectory,
  verifyNodeHost,
} from "./unix.mjs";

export const platformName = "linux";
export {
  configureUnixRuntimeEnvironment as configureRuntimeEnvironment,
  managedNeovimExecutable,
  managedNodeExecutable,
  managedToolExecutable,
  neovimDataDirectory,
  configureNodeHost,
  verifyNodeHost,
};

export function configureFonts() {
  try {
    executeCommand("fc-cache", [
      "-f",
      path.join(localDirectory, "share", "fonts"),
    ]);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}

export function verifyFonts() {
  const output = captureCommandOutput("fc-list", [":", "family"]);
  if (!output.toLowerCase().includes("jetbrainsmono nerd font")) {
    throw new Error("fontconfig cannot see JetBrainsMono Nerd Font");
  }
}
