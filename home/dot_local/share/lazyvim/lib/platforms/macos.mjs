export {
  configureNodeHost,
  configureUnixRuntimeEnvironment as configureRuntimeEnvironment,
  managedNeovimExecutable,
  managedNodeExecutable,
  managedToolExecutable,
  neovimDataDirectory,
  verifyNodeHost,
} from "./unix.mjs";

export const platformName = "darwin";

export function configureFonts() {}

export function verifyFonts() {
  const fontDirectory = path.join(
    targetHome,
    "Library",
    "Fonts",
    "JetBrainsMonoNerdFont",
  );
  const fontFiles = fs
    .readdirSync(fontDirectory)
    .filter((name) => name.endsWith(".ttf"));
  if (fontFiles.length === 0)
    throw new Error("No JetBrainsMono Nerd Font files installed");
  const catalog = captureCommandOutput("system_profiler", [
    "SPFontsDataType",
    "-json",
  ]);
  if (!catalog.toLowerCase().includes("jetbrainsmono")) {
    throw new Error("macOS font catalog cannot see JetBrainsMono Nerd Font");
  }
}
import fs from "node:fs";
import path from "node:path";
import { captureCommandOutput } from "../commands.mjs";
import { targetHome } from "../paths.mjs";
