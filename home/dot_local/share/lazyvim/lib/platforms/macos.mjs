export {
  configureUnixHost as configureHost,
  configureUnixRuntimeEnvironment as configureRuntimeEnvironment,
  managedNeovimExecutable,
  managedNodeExecutable,
  managedToolExecutable,
  neovimDataDirectory,
  verifyUnixHostIntegration as verifyHostIntegration,
} from "./unix.mjs";

export const platformName = "darwin";
