import { run } from "./lib/process.mjs";
import { home, isWindows, managedNvim } from "./lib/paths.mjs";

process.env.HOME = home;
process.env.USERPROFILE = home;
process.env.XDG_CONFIG_HOME = `${home}/.config`;
if (!isWindows) {
  process.env.XDG_DATA_HOME ||= `${home}/.local/share`;
  process.env.XDG_STATE_HOME ||= `${home}/.local/state`;
  process.env.XDG_CACHE_HOME ||= `${home}/.cache`;
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
  run(managedNvim, ["--headless", "-c", `lua ${lua}`, "+qa"]);
}

console.log("\nSync complete.");
