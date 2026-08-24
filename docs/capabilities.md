# Capability architecture

The repository is composed from user-visible capabilities. Operating systems are
adapters, not the top-level architecture.

## Contract

Every Node capability exports a definition with:

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
│   ├── enhanced by language.go ───── requires node
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
├── capabilities/
│   ├── registry.mjs
│   ├── foundation.mjs
│   ├── fonts.mjs
│   ├── node.mjs
│   ├── nvim.mjs
│   ├── tmux.mjs
│   └── languages/
│       ├── go.mjs
│       ├── typescript.mjs
│       └── ...
├── platforms/              host-operation adapters
└── run.mjs                 lifecycle entry point

dot_config/nvim/lua/
├── plugins/                base Neovim capability
└── capabilities/
    ├── extras/             LazyVim extras, imported before custom plugins
    └── plugins/            language-specific custom specs, imported last
```

Provisioning follows the same ownership boundary: capability-specific files in
`.chezmoiexternals/` declare downloads, while platform selection remains inside
those templates. Shared versions have one source of truth.

## Behavioral verification

Verification belongs to the capability that promises the behavior:

- Node resolves through the configured environment and runs the pinned version.
- tmux starts, loads its theme, and runs pinned plugins.
- Neovim starts and restores its locked state.
- Each language enhancement opens a real fixture, parses it, and attaches the
  expected LSP. Formatter enhancements must transform a fixture on disk.
- Font verification checks registration/cache visibility, not only archive
  extraction.

Directory existence is diagnostic evidence only; it is never sufficient proof
that a capability works.

## Migration plan

1. Introduce and validate the capability registry and lifecycle runner.
2. Move Node, fonts, tmux, Neovim, and tool behavior out of platform-oriented
   orchestration into capability modules.
3. Express languages as Neovim enhancements and move their lazy.nvim specs into
   `lua/capabilities/`.
4. Split the external manifest by capability without changing targets or pins.
5. Make local sync and CI invoke the same lifecycle runner.
6. Run clean-home Linux, macOS, and Windows behavioral verification.

## Research basis

- [chezmoi special files](https://www.chezmoi.io/reference/special-files/)
- [chezmoi external manifests](https://www.chezmoi.io/reference/special-files/chezmoiexternal-format/)
- [chezmoi templates](https://www.chezmoi.io/user-guide/templating/)
- [lazy.nvim plugin spec](https://lazy.folke.io/spec)
- [LazyVim plugin composition](https://www.lazyvim.org/configuration/plugins)
- [Neovim LSP activation](https://neovim.io/doc/user/lsp/)
- [Node ECMAScript modules](https://nodejs.org/api/esm.html)
