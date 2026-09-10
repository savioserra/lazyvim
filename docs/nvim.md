# Neovim reference

| Property | Value |
| --- | --- |
| Target | `~/.config/nvim` |
| Distribution | LazyVim |
| Plugin manager | lazy.nvim |
| Managed source | `workstation/packages/nvim/files/.config/nvim/` (recipes in `packages/nvim/init.lua`) |

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
| `lua/languages/profile.lua` | Generated language imports, prerequisites, verification cases |
| `lua/languages/plugins/*.lua` | Profile-referenced custom specs |
| `lazyvim.json` | Base LazyVim extras |
| `neoconf.json` | Project settings import policy |

## Profile fields

The deployed
[`languages/profile.lua`](../workstation/packages/nvim/init.lua) is **generated**
by the nvim-owned compositor from declared `nvim-profile` recipes
(base/standard/Go from `packages/nvim`, language entries from their own
capabilities such as `packages/typescript`), ordered Go, TypeScript, standard.
The engine
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

`packages/typescript/files/languages/plugins/typescript.lua` returns lazy.nvim
plugin specs — TypeScript/JavaScript LSP ownership, completion and editor
commands — deployed as a plain runtime module. The `packages/typescript`
capability owns it, declares the profile intent (`plugin_module =
"languages.plugins.typescript"`) and verifies its own behavior through the
nvim leaf helpers; `workstation/packages/nvim/` owns editor sync, locks and
base/standard/Go verification; `node` owns the host runtime. Deployed Neovim
imports runtime configuration only, never package factories or engine modules.

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

`lazy-lock.json` is engine-seeded, runtime-extended mutable application
state, not byte-owned configuration: it deploys through a package-owned
whole-body `modify` merge program
(`files/modify/lazy-lock.json.sh` with the committed asset embedded verbatim),
never a whole-file recipe. Absent targets seed the baseline byte-for-byte;
drifted copies reconcile: engine pins win, host extras with an installed
plugin directory are preserved, stale extras are pruned, and malformed input
fails closed. Verify asserts every engine pin is present at its exact
branch/commit and installed at that commit; host extras are reported
audit-only (bounding them by class would couple the engine to whatever
external spec source produced them). Consequences: the deployed file carries
mode 0755 because modify programs deploy as executable, and `workstation
diff` stays the readable surface for effective lockfile changes (`plan` shows
the program body with its embedded pin block).

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
- Keep tender.vim in the specs unconditionally so the spec set and headless
  sync stay host-independent. The deployed lockfile may still legitimately
  gain host extras (the followed theme's plugin); the merge program
  reconciles them at the next apply instead of failing closed.

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
