import { captureCommandOutput } from "../../lib/commands.mjs";
import { defineCapability } from "../contract.mjs";

export default defineCapability({
  id: "language.go",
  requires: ["nvim"],
  enhancements: {
    nvim: [
      {
        extrasModule: "capabilities.extras.go",
        lazyvimExtras: ["lazyvim.plugins.extras.lang.go"],
        languageCases: [
          {
            language: "go",
            filename: "attachment_test.go",
            contents: "package behavior\n\nvar answer = 42\n",
            client: "gopls",
          },
        ],
      },
    ],
  },
  verify({ platform, versions }) {
    const actual = captureCommandOutput(platform.managedToolExecutable("go"), [
      "version",
    ]);
    if (!actual.startsWith(`go version go${versions.go}`)) {
      throw new Error(`Unexpected Go version: ${actual}`);
    }
  },
});
