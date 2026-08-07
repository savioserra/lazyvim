# Original setup analysis

> Lifecycle command references in this historical analysis were subsequently migrated to the Go/Cobra CLI. See [go-migration.md](go-migration.md).

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

The original tmux session used a 500 ms escape delay, disabled focus events, and did not advertise true-color support. The managed `home/dot_tmux.conf` now resolves those observations with a 10 ms delay, focus forwarding, `tmux-256color`, and an idempotent `xterm-256color:RGB` terminal feature. The installer reloads an active tmux server after applying the file.

Other health warnings are optional for this plugin set:

- image rendering needs a Kitty-protocol terminal and ImageMagick;
- LaTeX/Mermaid previews need TeX and `mmdc`;
- Node, Python, Ruby, and Perl Neovim providers are absent, but no configured plugin currently requires them;
- some Snacks checks report lazy-loaded UI integrations as not set during a headless health run.

## Repository model

The first version used a package-oriented link repository. Once tmux and general configuration synchronization entered scope, it migrated to a chezmoi source state:

- `home/dot_config/nvim` maps to `~/.config/nvim`;
- `home/dot_tmux.conf` maps to `~/.tmux.conf` on Linux, macOS, and WSL;
- native Windows ignores tmux and junctions `%LOCALAPPDATA%\nvim` to the applied configuration under the user profile;
- live changes are captured with `dotfiles capture`, while repository changes are deployed with `dotfiles apply`;
- typed Go catalogs select the supported runtime platform and archive layouts;
- every replaced unmanaged target gets a timestamped backup;
- machine-generated data/state/cache stays outside Git;
- checksummed host tools and both lockfiles provide a practical reproducibility boundary.

Chezmoi is itself pinned and checksummed by the installers. This preserves fresh-host bootstrapping without requiring a preinstalled dotfile manager, while enabling future host templates and encrypted values.
