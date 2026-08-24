import {
  configureNvmDefaultOnUnix,
  configureWindowsUserEnvironment,
} from "./lib/environment.mjs";
import { refreshLinuxFontCache, registerWindowsFonts } from "./lib/fonts.mjs";
import { platform } from "./lib/platform.mjs";
import { synchronizeTmuxPlugins } from "./lib/tmux.mjs";

if (platform.isWindows) {
  configureWindowsUserEnvironment();
  registerWindowsFonts();
} else {
  configureNvmDefaultOnUnix();
  synchronizeTmuxPlugins();
  if (platform.isLinux) refreshLinuxFontCache();
}
