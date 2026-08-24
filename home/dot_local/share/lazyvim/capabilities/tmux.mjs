import {
  synchronizeTmuxPlugins,
  verifyTmuxConfiguration,
} from "../lib/tmux.mjs";
import { defineCapability } from "./contract.mjs";

export default defineCapability({
  id: "tmux",
  requires: ["foundation"],
  supports: ({ platform }) => platform.platformName !== "win32",
  setup() {
    synchronizeTmuxPlugins();
  },
  verify() {
    verifyTmuxConfiguration();
  },
});
