# Neovim configuration instructions

Scope: `home/dot_config/nvim/**`.

## Composition order

1. LazyVim base plugins.
2. `languages/profile.lua` LazyVim extras.
3. Base `lua/plugins/` specs.
4. Profile custom plugin modules.

Do not reintroduce `lua/languages/extras/`; the profile is the source of truth.

## Language changes

For each language contribution:

- set a stable profile `id`;
- declare host capability prerequisites in `requires`;
- list LazyVim imports in `lazyvim_extras`;
- reference custom specs with `plugin_module`;
- add Mason packages to `mason_packages` and `mason-lock.json`;
- add parser/LSP behavior cases;
- add formatter cases when formatting is promised.

## Lock ownership

| State | Source of truth |
| --- | --- |
| Plugins | `lazy-lock.json` |
| Mason packages | `mason-lock.json` |
| Language composition | `lua/languages/profile.lua` |
| Base LazyVim extras | `lazyvim.json` |
| Tree-sitter parser set | `lua/plugins/treesitter.lua` plus locked plugin commit |

Keep headless-sync branching at the integration boundary. Use
`LAZYVIM_HEADLESS_SYNC`; do not reference capability-runtime internals from
normal plugin modules.
