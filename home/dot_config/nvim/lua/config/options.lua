-- Options are loaded before lazy.nvim starts.
-- LazyVim defaults: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua

-- Keep Prettier as the sole JS/TS formatter; ESLint provides diagnostics and fixes.
vim.g.lazyvim_eslint_auto_format = false

-- Only run Prettier in projects that explicitly configure it.
vim.g.lazyvim_prettier_needs_config = true

-- Use nvim-cmp for completion.
vim.g.lazyvim_cmp = "nvim-cmp"

-- Neoconf files use the jsonc filetype; the JSON parser supports its syntax.
vim.treesitter.language.register("json", "jsonc")

-- Use native rounded borders and reserve the tabline for actual Neovim tabs.
vim.opt.winborder = "rounded"
vim.opt.showtabline = 1

-- noice.nvim renders the cmdline as a popup, so the reserved cmdline row at
-- the bottom is otherwise unused dead space between lualine and tmux's status
-- bar. Removing it closes that gap.
vim.opt.cmdheight = 0
