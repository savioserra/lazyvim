import { captureCommandOutput } from "../lib/commands.mjs";
import { defineCapability } from "./contract.mjs";

export default defineCapability({
  id: "language.node",
  requires: ["foundation"],
  setup({ platform }) {
    platform.configureNodeHost();
  },
  verify({ platform, versions }) {
    platform.verifyNodeHost();
    const actual = captureCommandOutput("node", ["--version"]);
    if (actual !== `v${versions.node}`) {
      throw new Error(`Expected managed Node v${versions.node}, got ${actual}`);
    }
  },
});
