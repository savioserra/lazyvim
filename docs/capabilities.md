# Capability architecture

The repository is composed from user-visible capabilities. Operating systems are
adapters, not the top-level architecture.

## Contract

Every Lua capability returns a definition with:

- `id`: stable capability name.
- `requires`: capabilities that must run first.
- `supports(context)`: whether the current platform supports it.
- lifecycle hooks: `setup`, `sync`, and `verify`.
- `enhancements`: contributions to another capability.

The registry validates definitions, rejects missing dependencies and cycles,
filters unsupported capabilities, applies enhancements, and executes each
lifecycle in dependency order. A hook receives only the shared runtime context
and its composed enhancements.

Platform modules implement host operations used by capabilities. They never
choose which capabilities exist. For example, the tmux capability declares that
it is unsupported on Windows; the Windows adapter does not contain a tmux no-op.

## Graph

```text
foundation
├── fonts
├── node
├── nvim
│   ├── enhanced by language.lua
│   ├── enhanced by language.go ───────── requires node
│   ├── enhanced by language.typescript ─ requires node
│   └── enhanced by language.web
└── tmux (Linux/macOS only)
```

An enhancement is data plus behavior. A language contribution can add LazyVim
specs, Mason packages, Tree-sitter parsers, LSP attachment cases, formatter
cases, or other Neovim behavior without adding language-specific branches to
the Neovim capability.

## Ownership

```text
dot_local/share/lazyvim/
├── run.lua                   lifecycle entry point
├── versions.json             shared by provisioning and verification
└── lua/setup/
    ├── registry.lua
    ├── capabilities/
    │   ├── foundation.lua
    │   ├── fonts.lua
    │   ├── node.lua
    │   ├── nvim.lua
    │   └── tmux.lua
    ├── enhancements/          language setup and behavior-test metadata
    │   ├── go.lua
    │   ├── typescript.lua
    │   └── ...
    └── platforms/            same contract, per-OS implementations

dot_config/nvim/lua/
├── plugins/                  base Neovim capability
└── languages/
    ├── extras/               LazyVim extras, imported before custom plugins
    └── plugins/              language-specific custom specs, imported last
```

Provisioning follows the same ownership boundary: capability-specific files in
`.chezmoiexternals/` declare downloads, while platform selection remains inside
those templates. Shared versions have one source of truth.

## Behavioral verification

Verification belongs to the capability that promises the behavior:

- Node resolves through the configured environment and runs the pinned version.
- tmux starts, loads its theme, and runs pinned plugins.
- Neovim starts and restores its locked state without the LazyVim import-order warning.
- Each language enhancement opens a real fixture, parses it, and attaches the
  expected LSP. Formatter enhancements must transform a fixture on disk.
- Font verification checks registration/cache visibility, not only archive extraction.

Directory existence is diagnostic evidence only; it is never sufficient proof
that a capability works.

## Runtime migration

The lifecycle uses the pinned Neovim binary as its cross-platform Lua runtime,
so orchestration does not depend on Node being configured first. See
[lua-migration.md](lua-migration.md) for the decision, bootstrap sequence, and
official documentation used to validate it.

## Research basis

- [chezmoi special files](https://www.chezmoi.io/reference/special-files/)
- [chezmoi external manifests](https://www.chezmoi.io/reference/special-files/chezmoiexternal-format/)
- [chezmoi templates](https://www.chezmoi.io/user-guide/templating/)
- [lazy.nvim plugin spec](https://lazy.folke.io/spec)
- [LazyVim plugin composition](https://www.lazyvim.org/configuration/plugins)
- [Neovim LSP activation](https://neovim.io/doc/user/lsp/)
- [Neovim command-line Lua execution](https://neovim.io/doc/user/starting/)
- [Neovim Lua modules](https://neovim.io/doc/user/lua/)
