# Lua runtime migration

## Decision

Pinned Neovim is the capability runtime. `nvim -l run.lua <lifecycle>` executes
setup and verification without loading user configuration. The Neovim capability
launches separate configured child instances for plugin synchronization and
editor behavior tests.

Node remains a managed language capability, but it no longer controls setup.

## Runtime layout

```text
dot_local/share/lazyvim/
├── run.lua
├── versions.json
└── lua/setup/
    ├── registry.lua
    ├── context.lua
    ├── capabilities/
    └── platforms/
```

The capability contract remains `id`, `requires`, `supports`, `enhancements`,
and optional `setup`, `sync`, and `verify` hooks. The registry validates and
topologically orders the graph before executing a lifecycle.

## Bootstrap

1. chezmoi applies checksum-pinned externals, including Neovim.
2. The platform's tiny shell launcher invokes pinned Neovim with `-l run.lua setup`.
3. `sync`/`sync.ps1` apply chezmoi and invoke `-l run.lua sync`.
4. Local and CI verification invoke `-l run.lua verify`.

## Research basis

- [Neovim `-l` startup mode](https://neovim.io/doc/user/starting/)
- [Neovim Lua standard library and module loading](https://neovim.io/doc/user/lua/)
- [Neovim Lua module guide](https://neovim.io/doc/user/lua-guide/)
- [lazy.nvim imported specs](https://lazy.folke.io/spec)
- [lazy.nvim spec structure](https://lazy.folke.io/usage/structuring)
