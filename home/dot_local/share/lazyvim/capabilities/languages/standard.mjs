import { defineCapability } from "../contract.mjs";

export default defineCapability({
  id: "language.standard",
  requires: ["nvim"],
  enhancements: {
    nvim: [
      {
        extrasModule: "capabilities.extras.standard",
        lazyvimExtras: [
          "lazyvim.plugins.extras.lang.docker",
          "lazyvim.plugins.extras.lang.json",
          "lazyvim.plugins.extras.lang.markdown",
          "lazyvim.plugins.extras.lang.tailwind",
          "lazyvim.plugins.extras.lang.toml",
          "lazyvim.plugins.extras.lang.yaml",
        ],
        languageCases: [
          {
            language: "lua",
            filename: "attachment-test.lua",
            contents: "local answer = 42\n",
            client: "lua_ls",
          },
          {
            language: "html",
            filename: "attachment-test.html",
            contents: "<!doctype html><title>test</title>\n",
            client: "html",
          },
          {
            language: "css",
            filename: "attachment-test.css",
            contents: "body { color: red; }\n",
            client: "cssls",
          },
          {
            language: "json",
            filename: "attachment-test.json",
            contents: '{ "answer": 42 }\n',
            client: "jsonls",
          },
          {
            language: "yaml",
            filename: "attachment-test.yaml",
            contents: "answer: 42\n",
            client: "yamlls",
          },
          {
            language: "markdown",
            filename: "attachment-test.md",
            contents: "# Behavior test\n",
            client: "marksman",
          },
          {
            language: "dockerfile",
            filename: "Dockerfile",
            contents: "FROM scratch\n",
            client: "dockerls",
          },
        ],
      },
    ],
  },
});
