# Neovim config

Target: `~/.config/nvim`. Distribution: LazyVim, plugin manager: lazy.nvim.

## Entry points

| File | Role |
| --- | --- |
| `init.lua` | Bootstraps `config.lazy`; sets `vim.g.root_spec` to prefer `.git` root in monorepos |
| `lua/config/lazy.lua` | lazy.nvim setup (stock LazyVim bootstrap) |
| `lua/config/options.lua` | Non-default options (see table below) |
| `lua/config/keymaps.lua` | Custom keymaps (`<C-s>` save, `gl` go-to-line) |
| `lua/config/autocmds.lua` | Custom autocmds (organize-imports-on-save, external-file reload) |
| `lazyvim.json` | Enabled LazyVim extras (21 — coding/blink, lang.typescript, lang.go, dap.core, test.core, etc; full list in the file) |
| `neoconf.json` | Per-project VS Code settings import config (`lua_ls` enabled) |
| `stylua.toml` | Lua formatter config: 2-space indent, 120 column width |

## Non-default options (`lua/config/options.lua`)

| Option | Value | Effect |
| --- | --- | --- |
| `lazyvim_eslint_auto_format` | `false` | Prettier is the sole JS/TS formatter |
| `lazyvim_prettier_needs_config` | `true` | Prettier only runs where a project config exists |
| `lazyvim_cmp` | `"blink.cmp"` | Completion engine |
| `lazyvim_blink_main` | `false` | Uses blink.cmp's stable release, not `main` |
| `winborder` | `"rounded"` | Float/window border style |
| `showtabline` | `1` | Tabline only shows with >1 tab |
| `cmdheight` | `0` | Cmdline row hidden — noice.nvim renders it as a popup instead |

## `lua/plugins/*.lua`

| File | Owns |
| --- | --- |
| `lsp.lua` | nvim-lspconfig servers (gopls, tailwindcss, html, cssls, emmet), typescript-tools.nvim (owns all TS/JS LSP; `ts_ls`/`tsserver`/`vtsls`/`tsgo` disabled), `complete_capabilities()` (blink.cmp capability injection), workspace/symbol handler patch |
| `mason-lock.lua` | `zapling/mason-lock.nvim` — Mason lockfile plugin |
| `theme.lua` | `jacoborus/tender.vim` colorscheme + `fix_tender_contrast()` highlight overrides |
| `treesitter.lua` | Extra `ensure_installed` parsers: css, go, gomod, gosum, gowork, html, javascript, json, tsx, typescript |
| `ui.lua` | snacks.nvim, lualine.nvim (custom sections), noice.nvim (cmdline-popup only), dropbar.nvim, tiny-inline-diagnostic.nvim |
| `editor.lua` | vim-move, nvim-ts-autotag, vim-tmux-navigator, diffview.nvim |
| `testing.lua` | neotest + neotest-jest (nearest Jest config resolution for monorepos) |
| `debugging.lua` | nvim-dap + nvim-dap-view (replaces LazyVim's default dap-ui) |

## Lockfiles

| File | Package manager | Restore command | Notes |
| --- | --- | --- | --- |
| `lazy-lock.json` | lazy.nvim | `:Lazy restore` | Auto-installs missing plugins on startup; explicit restore only needed to fix drift |
| `mason-lock.json` | mason-lock.nvim | `:MasonLockRestore` | `:MasonLock` snapshots current versions; restore verifies exact versions and removes packages absent from the lock |

Tree-sitter parsers have no lockfile — `nvim-treesitter`'s `ensure_installed`/auto-install follows the locked plugin commit; `:TSUpdate` to force.

`plenary.nvim` is retained despite its upstream maintenance wind-down because both `typescript-tools.nvim` and LazyVim's DAP extra still import it directly. Remove it only after those active dependents migrate.
