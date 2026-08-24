import { executeCommand } from "./lib/commands.mjs";
import { targetHome } from "./lib/paths.mjs";
import {
  configureRuntimeEnvironment,
  managedNeovimExecutable,
} from "./lib/platforms/runtime.mjs";

process.env.HOME = targetHome;
process.env.USERPROFILE = targetHome;
process.env.XDG_CONFIG_HOME = `${targetHome}/.config`;
configureRuntimeEnvironment();

const operations = [
  ["Restoring Neovim plugins", "lazy-restore"],
  ["Removing inactive Neovim plugins", "lazy-clean"],
  ["Restoring Mason packages", "mason"],
  ["Updating Tree-sitter parsers", "treesitter"],
];

for (const [description, operation] of operations) {
  console.log(`\n==> ${description}`);
  const lua = `local ok, err = xpcall(function() require('config.sync').run('${operation}') end, debug.traceback); if not ok then io.stderr:write(err .. '\\n'); vim.cmd('cquit 1') end`;
  executeCommand(managedNeovimExecutable, [
    "--headless",
    "-c",
    `lua ${lua}`,
    "+qa",
  ]);
}

console.log("\nSync complete.");
