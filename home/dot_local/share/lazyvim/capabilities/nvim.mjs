import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { captureCommandOutput, executeCommand } from "../lib/commands.mjs";
import { defineCapability } from "./contract.mjs";

function requireCondition(condition, message) {
  if (!condition) throw new Error(message);
}

function runNeovimLua(executable, lua) {
  captureCommandOutput(executable, ["--headless", "-c", `lua ${lua}`, "+qa"]);
}

function verifyLockedState({ platform, targetHome, versions }) {
  const firstLine = captureCommandOutput(platform.managedNeovimExecutable, [
    "--version",
  ]).split(/\r?\n/)[0];
  requireCondition(
    firstLine === `NVIM v${versions.neovim}`,
    `Unexpected Neovim: ${firstLine}`,
  );
  requireCondition(
    captureCommandOutput("nvim", ["--version"]).split(/\r?\n/)[0] === firstLine,
    "The configured environment does not resolve managed Neovim",
  );
  const configDirectory = path.join(targetHome, ".config", "nvim");
  for (const [lockName, installedDirectory] of [
    ["lazy-lock.json", path.join(platform.neovimDataDirectory, "lazy")],
    [
      "mason-lock.json",
      path.join(platform.neovimDataDirectory, "mason", "packages"),
    ],
  ]) {
    const lock = JSON.parse(
      fs.readFileSync(path.join(configDirectory, lockName), "utf8"),
    );
    for (const name of Object.keys(lock)) {
      requireCondition(
        fs.existsSync(path.join(installedDirectory, name)),
        `Missing ${lockName} entry: ${name}`,
      );
    }
  }
}

function verifyEnhancementContracts(context) {
  const masonLock = JSON.parse(
    fs.readFileSync(
      path.join(context.targetHome, ".config", "nvim", "mason-lock.json"),
      "utf8",
    ),
  );
  for (const enhancement of context.enhancements) {
    for (const packageName of enhancement.masonPackages || []) {
      requireCondition(
        masonLock[packageName],
        `Neovim enhancement requires unlocked Mason package ${packageName}`,
      );
    }
    if (!enhancement.pluginModule) continue;
    const expectedImports = JSON.stringify(enhancement.lazyvimExtras || []);
    const lua = [
      `local spec = require('${enhancement.pluginModule}')`,
      "local imports = {}",
      "for _, item in ipairs(spec) do if item.import then imports[item.import] = true end end",
      `for _, name in ipairs(vim.json.decode('${expectedImports}')) do`,
      " if not imports[name] then error('missing capability import: ' .. name) end",
      "end",
    ].join("; ");
    runNeovimLua(context.platform.managedNeovimExecutable, lua);
  }
}

function verifyLanguageCase(executable, directory, testCase) {
  const sourceFile = path.join(directory, testCase.filename);
  fs.writeFileSync(sourceFile, testCase.contents);
  const escapedFile = sourceFile.replaceAll("\\", "/").replaceAll("'", "''");
  const lua = [
    `vim.cmd("edit " .. vim.fn.fnameescape('${escapedFile}'))`,
    "local parser_ok, parser = pcall(vim.treesitter.get_parser, 0)",
    `if not parser_ok then error('${testCase.language} parser unavailable: ' .. tostring(parser)) end`,
    "parser:parse()",
    "local attached = vim.wait(15000, function()",
    " for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do",
    `  if client.name == '${testCase.client}' then return true end`,
    " end",
    " return false",
    "end, 100)",
    `if not attached then error('${testCase.client} did not attach to ${testCase.language}') end`,
  ].join("; ");
  runNeovimLua(executable, lua);
}

function verifyFormatterCase(executable, directory, testCase) {
  for (const [name, contents] of Object.entries(testCase.projectFiles || {})) {
    fs.writeFileSync(path.join(directory, name), contents);
  }
  const sourceFile = path.join(directory, testCase.filename);
  fs.writeFileSync(sourceFile, testCase.contents);
  const escapedFile = sourceFile.replaceAll("\\", "/").replaceAll("'", "''");
  runNeovimLua(
    executable,
    [
      `vim.cmd("edit " .. vim.fn.fnameescape('${escapedFile}'))`,
      "require('conform').format({ async = false, timeout_ms = 15000 })",
      "vim.cmd('write')",
    ].join("; "),
  );
  requireCondition(
    fs.readFileSync(sourceFile, "utf8") === testCase.expected,
    `${testCase.language} formatter did not produce expected output`,
  );
}

export default defineCapability({
  id: "nvim",
  requires: ["foundation", "language.node"],
  sync({ platform }) {
    const operations = [
      ["Restoring Neovim plugins", "lazy-restore"],
      ["Removing inactive Neovim plugins", "lazy-clean"],
      ["Restoring Mason packages", "mason"],
      ["Updating Tree-sitter parsers", "treesitter"],
    ];
    for (const [description, operation] of operations) {
      console.log(`\n  -> ${description}`);
      const lua = `local ok, err = xpcall(function() require('config.sync').run('${operation}') end, debug.traceback); if not ok then io.stderr:write(err .. '\\n'); vim.cmd('cquit 1') end`;
      executeCommand(platform.managedNeovimExecutable, [
        "--headless",
        "-c",
        `lua ${lua}`,
        "+qa",
      ]);
    }
  },
  verify(context) {
    verifyLockedState(context);
    verifyEnhancementContracts(context);
    const temporaryDirectory = fs.mkdtempSync(
      path.join(os.tmpdir(), "lazyvim-capabilities-"),
    );
    try {
      for (const enhancement of context.enhancements) {
        for (const testCase of enhancement.languageCases || []) {
          verifyLanguageCase(
            context.platform.managedNeovimExecutable,
            temporaryDirectory,
            testCase,
          );
        }
        for (const testCase of enhancement.formatterCases || []) {
          verifyFormatterCase(
            context.platform.managedNeovimExecutable,
            temporaryDirectory,
            testCase,
          );
        }
      }
    } finally {
      fs.rmSync(temporaryDirectory, { recursive: true, force: true });
    }
  },
});
