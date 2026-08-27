# Neovim reference

| Property | Value |
| --- | --- |
| Target | `~/.config/nvim` |
| Distribution | LazyVim |
| Plugin manager | lazy.nvim |
| Managed source | `home/dot_config/nvim/` |

## Startup and composition

| Order | Source |
| --- | --- |
| 1 | `LazyVim/LazyVim`, import `lazyvim.plugins` |
| 2 | `lua/languages/profile.lua` → `lazyvim_extras` |
| 3 | `lua/plugins/` |
| 4 | Profile `plugin_module` entries |

| File | Role |
| --- | --- |
| `init.lua` | Load `config.lazy`; set monorepo root preference |
| `lua/config/lazy.lua` | Bootstrap lazy.nvim; compose specs |
| `lua/config/options.lua` | Options |
| `lua/config/keymaps.lua` | Keymaps |
| `lua/config/autocmds.lua` | Autocommands |
| `lua/config/sync.lua` | Named blocking sync operations |
| `lua/languages/profile.lua` | Language imports, prerequisites, verification cases |
| `lua/languages/plugins/*.lua` | Profile-referenced custom specs |
| `lazyvim.json` | Base LazyVim extras |
| `neoconf.json` | Project settings import policy |

## Profile fields

See [`capabilities.md`](capabilities.md#neovim-profile) for the schema.

Rules:

- Put every language-specific LazyVim import in the profile.
- Put profile extras before base custom plugins.
- Put profile custom modules after base custom plugins.
- Declare required host capabilities with `requires`.
- Add a real parser/LSP behavior case for supported languages.
- Add an on-disk case for promised formatters.
- Keep Mason requirements present in `mason-lock.json`.

## Plugin ownership

| File | Owns |
| --- | --- |
| `lsp.lua` | Base nvim-lspconfig servers |
| `mason.lua` | Headless sync integration |
| `mason-lock.lua` | Blocking exact Mason restore |
| `theme.lua` | tender.vim and contrast overrides |
| `treesitter.lua` | Parser set |
| `ui.lua` | snacks, lualine, noice, dropbar, inline diagnostics |
| `editor.lua` | Movement, tags, tmux navigation, diff view |
| `testing.lua` | neotest and Jest adapter |
| `debugging.lua` | nvim-dap and nvim-dap-view |

## Lockfiles

| State | File | Restore |
| --- | --- | --- |
| Plugins | `lazy-lock.json` | `:Lazy restore` |
| Mason tools | `mason-lock.json` | `:MasonLockRestore` |
| Tree-sitter parsers | Parser config + locked plugin | `:TSUpdate` |

Mason restore requirements:

- install exact locked versions;
- remove packages absent from the lock;
- suppress lock rewrites during restore;
- terminate timed-out operations;
- verify final installed versions.

## Headless sync

| Item | Value |
| --- | --- |
| Mode flag | `LAZYVIM_HEADLESS_SYNC=1` |
| Dispatcher | `packages/nvim/child.lua` |
| Operations | `lazy-restore`, `lazy-clean`, `mason`, `treesitter` |

Keep mode-specific behavior at `plugins/mason.lua` and the child integration
boundary. Do not import capability-runtime modules from normal editor specs.

## Notable options

| Option/global | Value |
| --- | --- |
| `lazyvim_eslint_auto_format` | `false` |
| `lazyvim_prettier_needs_config` | `true` |
| `lazyvim_cmp` | `blink.cmp` |
| `lazyvim_blink_main` | `false` |
| `winborder` | `rounded` |
| `showtabline` | `1` |
| `cmdheight` | `0` |
