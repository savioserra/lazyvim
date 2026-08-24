import { captureCommandOutput } from "../lib/commands.mjs";
import { defineCapability } from "./contract.mjs";

function expectPrefix(actual, expected, label) {
  if (!actual.startsWith(expected)) {
    throw new Error(`${label}: expected ${expected}, got ${actual}`);
  }
}

export default defineCapability({
  id: "foundation",
  verify({ platform, versions }) {
    expectPrefix(
      captureCommandOutput("rg", ["--version"]),
      `ripgrep ${versions.ripgrep}`,
      "ripgrep",
    );
    expectPrefix(
      captureCommandOutput("fd", ["--version"]),
      `fd ${versions.fdMajor}.`,
      "fd",
    );
    expectPrefix(
      captureCommandOutput("fzf", ["--version"]),
      versions.fzf,
      "fzf",
    );
    if (
      !captureCommandOutput("lazygit", ["--version"]).includes(
        `version=${versions.lazygit}`,
      )
    ) {
      throw new Error("Unexpected lazygit version");
    }
    if (
      !captureCommandOutput("tree-sitter", ["--version"]).includes(
        versions.treeSitter,
      )
    ) {
      throw new Error("Unexpected tree-sitter version");
    }
    const rainfrog = platform.managedToolExecutable("rainfrog");
    if (!(platform.platformName === "win32" && process.arch === "arm64")) {
      captureCommandOutput(rainfrog, ["--version"]);
    }
  },
});
