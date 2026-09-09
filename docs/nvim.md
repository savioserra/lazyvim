# Neovim reference

| Property | Value |
| --- | --- |
| Target | `~/.config/nvim` |
| Distribution | LazyVim |
| Plugin manager | lazy.nvim |
| Managed source | `chezmoi/dot_config/nvim/` |

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

The canonical [profile](../chezmoi/dot_config/nvim/lua/languages/profile.lua)
returns an ordered list of contribution tables. The engine
[validator](../workstation/packages/nvim/profile.lua) checks these fields:

| Field | Shape / use |
| --- | --- |
| `id` | Required unique non-empty string |
| `requires` | Optional list of non-empty host capability IDs; added to `nvim` dependencies |
| `lazyvim_extras` | Optional list of non-empty module names; imported before base custom specs |
| `plugin_module` | Optional non-empty module name; imported after base custom specs |
| `mason_packages` | Optional list of non-empty package names; verification requires entries in `mason-lock.json` |
| `language_cases` | Optional list of tables with non-empty strings `language`, `filename`, `contents`, `client`; real parser/LSP checks |
| `formatter_cases` | Optional list of tables with non-empty strings `language`, `filename`, `contents`, `expected`; on-disk output checks |

Formatter cases also support `project_files`, a filename-to-contents map written
by the [verification consumer](../workstation/packages/nvim/init.lua) before the
source file. The profile validator does not validate that map or reject unknown
fields; its list checks use `ipairs`, not a strict dense-array schema.

Put language-specific LazyVim imports here, include parser/LSP cases for supported
languages and formatter cases wherever formatting is promised. See
[target-first engine loading](capabilities.md#neovim-package-and-profile).

### Editor specs versus lifecycle packages

`lua/languages/plugins/typescript.lua` currently returns lazy.nvim plugin specs:
it configures TypeScript/JavaScript LSP ownership, completion and editor commands.
The profile imports it as `languages.plugins.typescript` and requires the `node`
host capability. It is not a catalog factory returning lifecycle handlers.
`workstation/packages/nvim/` owns editor sync/verification; `node` owns the host
runtime. This describes the present split, not a permanent requirement that all
language payloads must stay outside workstation packages.

## Plugin ownership

| File | Owns |
| --- | --- |
| `lsp.lua` | Base nvim-lspconfig servers |
| `mason.lua` | Headless sync integration |
| `mason-lock.lua` | Blocking exact Mason restore |
| `theme.lua` | tender.vim, contrast overrides, and guarded Omarchy desktop-theme import |
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

## Desktop theme integration

| Item | Value |
| --- | --- |
| Followed spec | `~/.local/state/omarchy/current/theme/neovim.lua` (legacy `~/.config/omarchy/current/theme/…`) |
| Mechanism | `lua/plugins/theme.lua` loads the spec at startup and appends it after the tender specs |
| Fallback | tender on non-Omarchy hosts, missing files, empty specs, or load errors |

Rules:

- Apply the imported colorscheme on the next Neovim start; running instances
  only get the terminal-palette retint, so a colorscheme reload needs a
  restart (stock Omarchy behaves the same way).
- Keep tender.vim in the specs unconditionally so lockfile and headless sync
  state stay host-independent.

## Headless sync

| Item | Value |
| --- | --- |
| Mode flag | `LAZYVIM_HEADLESS_SYNC=1` |
| Dispatcher | `workstation/packages/nvim/child.lua` |
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
