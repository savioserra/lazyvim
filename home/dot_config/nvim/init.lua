-- bootstrap lazy.nvim, LazyVim and your plugins
require("config.lazy")

-- Force root detection to prefer the repository root in monorepos.
vim.g.root_spec = { ".git", "lsp", "cwd" }
