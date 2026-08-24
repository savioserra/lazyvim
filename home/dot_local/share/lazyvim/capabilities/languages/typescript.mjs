import { defineCapability } from "../contract.mjs";

export default defineCapability({
  id: "language.typescript",
  requires: ["language.node", "nvim"],
  enhancements: {
    nvim: [
      {
        extrasModule: "capabilities.extras.typescript",
        pluginModule: "capabilities.plugins.typescript",
        lazyvimExtras: [
          "lazyvim.plugins.extras.lang.typescript",
          "lazyvim.plugins.extras.linting.eslint",
          "lazyvim.plugins.extras.formatting.prettier",
        ],
        masonPackages: ["typescript-language-server", "eslint-lsp", "prettier"],
        languageCases: [
          {
            language: "javascript",
            filename: "attachment-test.js",
            contents: "const answer = 42;\n",
            client: "typescript-tools",
          },
        ],
        formatterCases: [
          {
            language: "javascript",
            filename: "format-test.js",
            contents: "const answer=42\n",
            expected: "const answer = 42;\n",
            projectFiles: { ".prettierrc.json": "{}\n" },
          },
        ],
      },
    ],
  },
});
