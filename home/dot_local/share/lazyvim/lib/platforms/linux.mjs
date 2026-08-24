import path from "node:path";
import { executeCommand } from "../commands.mjs";
import { localDirectory } from "../paths.mjs";
import {
  configureUnixHost,
  configureUnixRuntimeEnvironment,
  managedNeovimExecutable,
  managedNodeExecutable,
  managedToolExecutable,
  neovimDataDirectory,
  verifyUnixHostIntegration,
} from "./unix.mjs";

export const platformName = "linux";
export {
  configureUnixRuntimeEnvironment as configureRuntimeEnvironment,
  managedNeovimExecutable,
  managedNodeExecutable,
  managedToolExecutable,
  neovimDataDirectory,
  verifyUnixHostIntegration as verifyHostIntegration,
};

export function configureHost() {
  configureUnixHost();
  try {
    executeCommand("fc-cache", [
      "-f",
      path.join(localDirectory, "share", "fonts"),
    ]);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}
