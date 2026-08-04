# Neovim dotfiles

A package-oriented dotfiles monorepository for installing, maintaining, and synchronizing this LazyVim setup. It captures the configuration, editor binary, companion CLI tools, plugin revisions, Mason package versions, and Nerd Font without committing generated runtime data.

## What is reproducible

| Layer | Source of truth |
| --- | --- |
| Neovim, ripgrep, fd, fzf, lazygit, tree-sitter CLI, font | `manifests/tools.env` (version, release URL, SHA-256) |
| LazyVim and Neovim plugins | `packages/nvim/lazy-lock.json` |
| LSP servers, formatters, linters, and debuggers | `packages/nvim/mason-lock.json` |
| Tree-sitter parsers | parser revisions supplied by the locked `nvim-treesitter` plugin |
| Configuration | `packages/nvim/` |

Generated plugins, tools, logs, caches, undo data, sessions, and editor history remain in the normal XDG data/state/cache directories and are rebuilt from the repository.

## Supported host

The release installer currently targets **Linux x86_64**. It does not require root and installs under `~/.local` by default.

Host prerequisites:

- Bash, Git, curl, tar, unzip, xz, jq, and SHA-256 utilities
- a C compiler and `make` for native plugins/parsers
- Node.js/npm and Go for the configured Mason packages
- optional: `xclip`, `tmux`, `inotify-tools`, and `fontconfig`

On Ubuntu/Zorin, the system utilities can be installed with:

```bash
sudo apt install build-essential curl git jq unzip xz-utils xclip inotify-tools fontconfig
```

Keep Node and Go in your preferred runtime manager (the current machine uses NVM and Snap respectively).

## Install on a new machine

```bash
git clone <your-repository-url> ~/Documents/Dev/dotfiles
cd ~/Documents/Dev/dotfiles
./scripts/install
```

The installer:

1. verifies pinned release artifacts before extracting them;
2. links `packages/nvim` to `~/.config/nvim`;
3. links the wrapper and companion tools into `~/.local/bin`;
4. restores plugins and Mason tools at locked versions;
5. installs missing Tree-sitter parsers.

Existing targets are moved—not deleted—to:

```text
~/.local/state/dotfiles/backups/<UTC timestamp>/
```

Ensure `~/.local/bin` is in `PATH`. Set `DOTFILES_OPT_HOME` or `DOTFILES_BIN_HOME` before installation to override the default binary locations.

## Daily maintenance

Because `~/.config/nvim` is a symlink, normal edits are made directly in this repository.

```bash
make check       # syntax, JSON, Stylua, lock versions, startup
make restore     # enforce both lockfiles after a rollback or pull
make lock-mason  # snapshot currently installed Mason versions
make update      # intentionally update plugins, Mason tools, and parsers
```

`make update` requires a clean worktree and leaves lockfile changes for review. Test them, inspect `git diff`, then commit and push. To roll back, restore an older Git commit and run `make restore`.

Host-side binaries update less frequently and deliberately stay outside `make update`. Change each version, release URL, and SHA-256 together in `manifests/tools.env`, run `make install`, and verify with `make check`.

## Synchronize machines

Create a private or public remote, then publish the initial branch:

```bash
git remote add origin <your-repository-url>
git push -u origin main
```

On each machine:

```bash
make sync
```

Sync refuses a dirty worktree, performs a fast-forward-only pull, reapplies links, restores the lockfiles, and runs checks. Configuration changes should be committed and pushed normally with Git.

## Repository layout

```text
.
├── manifests/tools.env       # pinned host-side release artifacts
├── packages/bin/nvim         # portable wrapper
├── packages/nvim/            # complete XDG Neovim configuration
├── scripts/                  # install/restore/update/check/sync lifecycle
├── docs/setup-analysis.md    # findings from the original machine
└── .github/workflows/ci.yml  # isolated headless startup validation
```

## Design references

The workflow follows the official recommendations to keep `lazy-lock.json` in version control and use `:Lazy restore` across machines. Mason has versioned installs but no core lockfile, so this repository records versions from Mason receipts and restores them through its official `:MasonInstall package@version` interface.

- [lazy.nvim lockfile](https://lazy.folke.io/usage/lockfile)
- [LazyVim installation](https://www.lazyvim.org/installation)
- [mason.nvim documentation](https://github.com/mason-org/mason.nvim/blob/main/doc/mason.txt)
- [Neovim standard paths](https://neovim.io/doc/user/starting.html#standard-path)
- [Neovim installation](https://neovim.io/doc/install/)
