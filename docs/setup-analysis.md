# Original setup analysis

Analyzed on 2026-08-04 before migration into this repository.

## Inventory

- Host: Zorin OS 18.1, Linux x86_64
- Neovim: 0.12.4 from `~/.local/opt/nvim-0.12.4`
- Distribution: LazyVim 8 on lazy.nvim
- Configuration size: about 84 KiB
- Generated Neovim data: about 973 MiB
- Plugin count: 45 entries in `lazy-lock.json`
- Mason packages: 26
- Tree-sitter parsers: 32 compiled parsers
- Font: JetBrainsMono Nerd Font 3.5.0
- Languages/workflows: Go, JavaScript, TypeScript, React/TSX, Tailwind, JSON, YAML, Docker, Markdown, TOML, Jest, and DAP

The setup starts headlessly and Neovim/LazyVim core health checks pass.

## Configuration behavior

- `vtsls` is the selected TypeScript LSP; `tsgo` remains configured as an optional alternative.
- JavaScript/TypeScript files organize imports synchronously before every save.
- Prettier is the sole JS/TS formatter and only runs in projects that explicitly configure it.
- ESLint provides diagnostics and code actions without competing for formatting.
- Neoconf imports selected VS Code JavaScript, TypeScript, and Tailwind settings per project.
- Tailwind completions recognize `clsx`, `classNames`, `cn`, and `cva`.
- Jest chooses the nearest config, which is suitable for Nx-style monorepositories.
- Go support includes gopls, formatting, linting, tests, and Delve.
- No user keymaps have been added; the setup currently uses LazyVim defaults.

The original single `lua/plugins/dev.lua` specification was split by concern into `editor.lua`, `lsp.lua`, `testing.lua`, and `treesitter.lua`. This changes organization, not behavior.

## Reproducibility gaps found

1. `~/.config/nvim` was not a Git worktree.
2. `lazy-lock.json` correctly pinned plugins, but there was no remote or restore workflow.
3. Mason packages were declarative at the package-name level but not version-locked.
4. Neovim and five companion tools lived in manually versioned `~/.local/opt` directories.
5. The Neovim launcher hard-coded the home directory and Neovim version.
6. The installed Nerd Font and its version were documented but not installable from the configuration.
7. There were no automated formatting, JSON, shell syntax, startup, or CI checks.
8. Runtime data was nearly 1 GiB; copying it would make a poor dotfiles repository and would sync machine-local history/state.

## Health observations

The actionable terminal warnings are outside Neovim itself:

- tmux `escape-time` is 500 ms; Neovim recommends at most 300 ms;
- tmux focus events are disabled, which can weaken file-change detection;
- true-color support was not detectable through the current tmux session.

A future tmux configuration could use:

```tmux
set -sg escape-time 10
set -g focus-events on
set -g default-terminal "tmux-256color"
set -as terminal-features ",xterm-256color:RGB"
```

Validate the terminal name before applying the last line; terminal overrides are host-specific and were intentionally not added to this Neovim-only repository.

Other health warnings are optional for this plugin set:

- image rendering needs a Kitty-protocol terminal and ImageMagick;
- LaTeX/Mermaid previews need TeX and `mmdc`;
- Node, Python, Ruby, and Perl Neovim providers are absent, but no configured plugin currently requires them;
- some Snacks checks report lazy-loaded UI integrations as not set during a headless health run.

## Chosen repository model

A package-oriented link repository was chosen over committing `~/.config/nvim` directly:

- it can grow to include tmux, shell, Git, or terminal packages without changing its lifecycle;
- the live configuration remains editable through the XDG path on Linux/macOS or `%LOCALAPPDATA%\nvim` on Windows;
- it supports Linux x86_64, Apple Silicon/Intel macOS, and ARM64/x64 Windows from one checksummed manifest;
- platform selection is isolated in `install-linux`, `install-macos`, and `install-windows.ps1`, while extraction/linking primitives stay shared;
- it avoids a runtime dependency on GNU Stow or a Windows dotfile manager;
- every replaced configuration target gets a timestamped backup;
- machine-generated data/state/cache stays outside Git;
- checksummed host tools and both lockfiles provide a practical reproducibility boundary.

Chezmoi would become preferable if this repository later needs secrets, encrypted values, or extensive host-specific templates. GNU Stow remains a good simpler alternative when only symlinks are needed, but the small repository-native linker avoids requiring it on a fresh host.
