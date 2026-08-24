import { executeCommand } from "./lib/commands.mjs";
import { managedNeovimExecutable, targetHome } from "./lib/paths.mjs";
import { platform } from "./lib/platform.mjs";

process.env.HOME = targetHome;
process.env.USERPROFILE = targetHome;
process.env.XDG_CONFIG_HOME = `${targetHome}/.config`;
if (!platform.isWindows) {
  process.env.XDG_DATA_HOME ||= `${targetHome}/.local/share`;
  process.env.XDG_STATE_HOME ||= `${targetHome}/.local/state`;
  process.env.XDG_CACHE_HOME ||= `${targetHome}/.cache`;
}

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
