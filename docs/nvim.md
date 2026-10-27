# Neovim reference

| Property | Value |
| --- | --- |
| Target | `~/.config/nvim` |
| Distribution | LazyVim |
| Plugin manager | lazy.nvim |
| Managed source | `modules/editor/nvim/files/.config/nvim/` |

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

The deployed `languages/profile.lua` is **composed natively**: the editor
capability's module (`modules/editor/editor.nix`) folds the language
entries the language capabilities declare (`workstation.editor.languages`)
through `lib.generators.toLua` in a build-time derivation — there is no
engine in the loop. Entries compose in id order (the base/standard
entry is the editor module's own). The declared fields:

| Field | Shape / use |
| --- | --- |
| `id` | Required unique non-empty string |
| `requires` | Optional list of non-empty host capability IDs |
| `lazyvim_extras` | Optional list of non-empty module names; imported before base custom specs |
| `plugin_module` | Optional non-empty module name; imported after base custom specs |
| `mason_packages` | Optional list of non-empty package names; verification requires entries in `mason-lock.json` |

The behavior cases (`language_cases`/`formatter_cases`) stay payload data:
they feed the verify lane's parser/LSP and formatter checks, not the
deployed file.

Put language-specific LazyVim imports here, include parser/LSP cases for supported
languages and formatter cases wherever formatting is promised. See
[target-first engine loading](capabilities.md#neovim-package-and-profile).

### Editor specs versus lifecycle packages

`modules/languages/typescript/files/languages/plugins/typescript.lua` returns lazy.nvim
plugin specs — TypeScript/JavaScript LSP ownership, completion and editor
commands — deployed as a plain runtime module. The `modules/languages/typescript/`
capability owns it, declares the profile intent (`plugin_module =
"languages.plugins.typescript"`) and verifies its own behavior through the
nvim leaf helpers; `modules/editor/nvim/` owns editor sync, locks and
base/standard/Go verification; `node` owns the host runtime. Deployed Neovim
imports runtime configuration only, never capability factories or engine modules.

`modules/languages/elixir/files/languages/plugins/elixir.lua` follows the same split
for Elixir/HEEx: the `modules/languages/elixir/` capability declares the profile intent
(the `lazyvim.plugins.extras.lang.elixir` extra, Mason's `elixir-ls`, attaching
as the `elixirls` client) and verifies real LSP attach plus `mix format`
formatting through the leaf helpers, while the deployed module constrains
ElixirLS (dialyzer and dep fetching off) and pins conform-owned
`mix format` as the autoformatter. The BEAM toolchain is the elixir
capability's nixpkgs runtime (erlang 28 + elixir 1.18, on PATH).

## Plugin ownership

| File | Owns |
| --- | --- |
| `lsp.lua` | Base nvim-lspconfig servers |
| `mason.lua` | Headless sync integration |
| `mason-lock.lua` | Blocking exact Mason restore |
| `theme.lua` | oasis.nvim (upstream starlight pin) + LazyVim colorscheme opt |
| `treesitter.lua` | Parser set |
| `ui.lua` | snacks, lualine, noice, dropbar, inline diagnostics, highlight colors |
| `editor.lua` | Movement, tags, tmux navigation, diff view |
| `testing.lua` | neotest and Jest adapter |
| `debugging.lua` | nvim-dap and nvim-dap-view |

## Lockfiles

| State | File | Restore |
| --- | --- | --- |
| Plugins | `lazy-lock.json` | `:Lazy restore` |
| Mason tools | `mason-lock.json` | `:MasonLockRestore` |
| Tree-sitter parsers | Parser config + locked plugin | `:TSUpdate` |

`lazy-lock.json` is substrate-seeded, runtime-extended mutable application
state, not byte-owned configuration:

- Deploys through a package-owned whole-body `modify` merge program
  (`files/modify/lazy-lock.json.sh`, the committed asset embedded
  verbatim) — never a whole-file recipe.
- Absent targets seed the baseline byte-for-byte.
- Drifted copies reconcile: substrate pins win; host extras with an
  installed plugin directory are preserved; stale extras are pruned;
  malformed input fails closed.
- Verify asserts every substrate pin at its exact branch/commit and
  installed at that commit; host extras are reported audit-only (bounding
  them by class would couple the editor to whatever external spec source
  produced them).
- The deployed file carries mode 0755 (modify programs deploy as
  executable); `workstation diff` is the readable surface for effective
  lockfile changes (`plan` shows the program body with its embedded pin
  block).

Mason restore requirements:

- install exact locked versions;
- remove packages absent from the lock;
- suppress lock rewrites during restore;
- terminate timed-out operations;
- verify final installed versions.

## Theme

| Item | Value |
| --- | --- |
| Colorscheme | `oasis-starlight` — `uhs-robert/oasis.nvim` pinned at `main` `a3ef178fe47c69691e676a8da98ce5735c3013db` in `lazy-lock.json` |
| Mechanism | `lua/plugins/theme.lua` runs `require("oasis").setup({ style = "starlight" })` then `vim.cmd.colorscheme("oasis-starlight")` at startup; LazyVim's `colorscheme` opt carries the same value |
| Dark/light | oasis switches on `vim.o.background` — both appearances map to its dual-mode palette natively (`light_intensity` 3 is the upstream default) |
| Omarchy import | Dropped with the Starlight rebrand: starlight wins on all hosts (rebrand spec S-R2), so the editor no longer follows the desktop theme |

Rules:

- oasis.nvim is the upstream port, deliberately NOT a colorscheme generated
  from the workstation tokens: tokens.lua drives engine surfaces; editor
  syntax rides the complete upstream palette (rebrand spec S-R4).
- Deployed lockfiles that still carry `tender.vim` (or Omarchy theme plugin
  extras) reconcile on the next apply: the pin left the seeded baseline, so it
  becomes a host extra that prunes once its installed plugin directory goes
  (documented lockfile merge semantics above).
- Apply the colorscheme on the next Neovim start; running instances only get
  the terminal-palette retint, so a colorscheme reload needs a restart.

## Headless sync

| Item | Value |
| --- | --- |
| Mode flag | `LAZYVIM_HEADLESS_SYNC=1` |
| Dispatcher | the deployed `lua/config/sync.lua` (headless nvim) |
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
