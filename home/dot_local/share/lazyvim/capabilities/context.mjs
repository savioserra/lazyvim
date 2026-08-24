import { targetHome } from "../lib/paths.mjs";
import * as platform from "../lib/platforms/runtime.mjs";
import { versions } from "../lib/versions.mjs";

export function createCapabilityContext() {
  process.env.HOME = targetHome;
  process.env.USERPROFILE = targetHome;
  process.env.XDG_CONFIG_HOME = `${targetHome}/.config`;
  platform.configureRuntimeEnvironment();
  return Object.freeze({ platform, targetHome, versions });
}
