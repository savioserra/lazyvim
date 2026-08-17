-- Options are loaded before lazy.nvim starts.
-- LazyVim defaults: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua

-- Use the native TypeScript language server for lower latency in large monorepos.
vim.g.lazyvim_ts_lsp = "tsgo"

-- Keep Prettier as the sole JS/TS formatter; ESLint provides diagnostics and fixes.
vim.g.lazyvim_eslint_auto_format = false

-- Only run Prettier in projects that explicitly configure it.
vim.g.lazyvim_prettier_needs_config = true

-- Use the stable blink.cmp release rather than its development branch.
vim.g.lazyvim_cmp = "blink.cmp"
vim.g.lazyvim_blink_main = false

-- Neoconf files use the jsonc filetype; the JSON parser supports its syntax.
vim.treesitter.language.register("json", "jsonc")

-- Use native rounded borders and reserve the tabline for actual Neovim tabs.
vim.opt.winborder = "rounded"
vim.opt.showtabline = 1
