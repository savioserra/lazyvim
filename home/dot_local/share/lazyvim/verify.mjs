import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { captureCommandOutput } from "./lib/commands.mjs";
import { targetHome } from "./lib/paths.mjs";
import {
  configureRuntimeEnvironment,
  managedNeovimExecutable,
  managedNodeExecutable,
  managedToolExecutable,
  neovimDataDirectory,
  platformName,
  verifyHostIntegration,
} from "./lib/platforms/runtime.mjs";
import { versions } from "./lib/versions.mjs";

function requireCondition(condition, failureMessage) {
  if (!condition) throw new Error(failureMessage);
}

function requireOutputPrefix(actualOutput, expectedPrefix, description) {
  requireCondition(
    actualOutput.startsWith(expectedPrefix),
    `${description}: expected ${expectedPrefix}, got ${actualOutput}`,
  );
}

function verifyManagedToolVersions() {
  requireCondition(
    captureCommandOutput(managedNeovimExecutable, ["--version"]).split(
      /\r?\n/,
    )[0] === `NVIM v${versions.neovim}`,
    "Unexpected Neovim version",
  );
  requireOutputPrefix(
    captureCommandOutput(managedToolExecutable("go"), ["version"]),
    `go version go${versions.go}`,
    "Go version",
  );
  requireCondition(
    captureCommandOutput(managedNodeExecutable, ["--version"]) ===
      `v${versions.node}`,
    "Unexpected Node.js version",
  );
  requireCondition(
    captureCommandOutput("node", ["--version"]) === `v${versions.node}`,
    "The configured environment does not resolve node to the managed version",
  );
  requireCondition(
    captureCommandOutput("nvim", ["--version"]).split(/\r?\n/)[0] ===
      `NVIM v${versions.neovim}`,
    "The configured environment does not resolve nvim to the managed version",
  );
  requireOutputPrefix(
    captureCommandOutput(managedToolExecutable("rg"), ["--version"]),
    `ripgrep ${versions.ripgrep}`,
    "ripgrep version",
  );
  requireOutputPrefix(
    captureCommandOutput(managedToolExecutable("fd"), ["--version"]),
    `fd ${versions.fdMajor}.`,
    "fd version",
  );
  requireOutputPrefix(
    captureCommandOutput(managedToolExecutable("fzf"), ["--version"]),
    versions.fzf,
    "fzf version",
  );
  requireCondition(
    captureCommandOutput(managedToolExecutable("lazygit"), [
      "--version",
    ]).includes(`version=${versions.lazygit}`),
    "Unexpected lazygit version",
  );
  requireCondition(
    captureCommandOutput(managedToolExecutable("tree-sitter"), [
      "--version",
    ]).includes(versions.treeSitter),
    "Unexpected tree-sitter version",
  );
}

function verifyNeovimDependencies() {
  const configDirectory = path.join(targetHome, ".config", "nvim");
  const pluginLock = JSON.parse(
    fs.readFileSync(path.join(configDirectory, "lazy-lock.json"), "utf8"),
  );
  for (const pluginName of Object.keys(pluginLock)) {
    requireCondition(
      fs.existsSync(path.join(neovimDataDirectory, "lazy", pluginName)),
      `Missing Neovim plugin: ${pluginName}`,
    );
  }
  const masonLock = JSON.parse(
    fs.readFileSync(path.join(configDirectory, "mason-lock.json"), "utf8"),
  );
  for (const packageName of Object.keys(masonLock)) {
    requireCondition(
      fs.existsSync(
        path.join(neovimDataDirectory, "mason", "packages", packageName),
      ),
      `Missing Mason package: ${packageName}`,
    );
  }
}

function verifyLanguageSupport() {
  const temporaryDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), "lazyvim-language-support-"),
  );
  const languageCases = [
    [
      "javascript",
      "attachment-test.js",
      "const answer = 42;\n",
      "typescript-tools",
    ],
    ["lua", "attachment-test.lua", "local answer = 42\n", "lua_ls"],
    [
      "go",
      "attachment_test.go",
      "package behavior\n\nvar answer = 42\n",
      "gopls",
    ],
    [
      "html",
      "attachment-test.html",
      "<!doctype html><title>test</title>\n",
      "html",
    ],
    ["css", "attachment-test.css", "body { color: red; }\n", "cssls"],
    ["json", "attachment-test.json", '{ "answer": 42 }\n', "jsonls"],
    ["yaml", "attachment-test.yaml", "answer: 42\n", "yamlls"],
    ["markdown", "attachment-test.md", "# Behavior test\n", "marksman"],
    ["dockerfile", "Dockerfile", "FROM scratch\n", "dockerls"],
  ];

  try {
    for (const [
      language,
      filename,
      contents,
      expectedClient,
    ] of languageCases) {
      const sourceFile = path.join(temporaryDirectory, filename);
      fs.writeFileSync(sourceFile, contents);
      const escapedFile = sourceFile
        .replaceAll("\\", "/")
        .replaceAll("'", "''");
      const lua = [
        `vim.cmd("edit " .. vim.fn.fnameescape('${escapedFile}'))`,
        "local parser_ok, parser = pcall(vim.treesitter.get_parser, 0)",
        `if not parser_ok then error('${language} Tree-sitter parser unavailable: ' .. tostring(parser)) end`,
        "parser:parse()",
        "local attached = vim.wait(15000, function()",
        "  for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do",
        `    if client.name == '${expectedClient}' then return true end`,
        "  end",
        "  return false",
        "end, 100)",
        `if not attached then error('${expectedClient} did not attach to ${language}') end`,
      ].join("; ");
      captureCommandOutput(managedNeovimExecutable, [
        "--headless",
        "-c",
        `lua ${lua}`,
        "+qa",
      ]);
    }
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

function verifyJavascriptFormatting() {
  const temporaryDirectory = fs.mkdtempSync(
    path.join(os.tmpdir(), "lazyvim-formatting-"),
  );
  const javascriptFile = path.join(temporaryDirectory, "format-test.js");
  fs.writeFileSync(javascriptFile, "const answer=42\n");
  fs.writeFileSync(path.join(temporaryDirectory, ".prettierrc.json"), "{}\n");
  const escapedFile = javascriptFile
    .replaceAll("\\", "/")
    .replaceAll("'", "''");
  const lua = [
    `vim.cmd("edit " .. vim.fn.fnameescape('${escapedFile}'))`,
    "require('conform').format({ async = false, timeout_ms = 15000 })",
    "vim.cmd('write')",
  ].join("; ");
  try {
    captureCommandOutput(managedNeovimExecutable, [
      "--headless",
      "-c",
      `lua ${lua}`,
      "+qa",
    ]);
    requireCondition(
      fs.readFileSync(javascriptFile, "utf8") === "const answer = 42;\n",
      "Prettier did not format JavaScript through Conform",
    );
  } finally {
    fs.rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}

configureRuntimeEnvironment();
verifyManagedToolVersions();
verifyNeovimDependencies();
verifyLanguageSupport();
verifyJavascriptFormatting();
verifyHostIntegration();

console.log(`Verified complete ${platformName} environment.`);
