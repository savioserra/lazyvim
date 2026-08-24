# Repository map

chezmoi-managed Neovim + tmux configuration for Linux, macOS, Windows. Lua modules running on the pinned Neovim provide shared orchestration; `sync` and `sync.ps1` only bootstrap them.

## Layout

```
.
├── README.md                    human install/workflow doc
├── sync / sync.ps1              minimal native bootstrap launchers
├── docs/                        this directory
├── .github/workflows/ci.yml     applies into a scratch HOME per platform
├── .github/workflows/release.yml publishes checksummed archives for v* tags
└── home/                        chezmoi source state (.chezmoiroot = "home")
    ├── .chezmoiversion            pinned chezmoi version
    ├── .chezmoiexternals/          pinned downloads split by capability — see tools.md
    ├── .chezmoiscripts/            managed Node launchers/bootstrap — see chezmoi.md
    ├── .chezmoiignore              platform-conditional exclusions
    ├── dot_local/bin/               -> ~/.local/bin
    ├── dot_local/share/lazyvim/     shared setup/sync/verification modules
    ├── dot_tmux.conf                -> ~/.tmux.conf — see tmux.md
    ├── dot_config/tmux/themes/      -> ~/.config/tmux/themes/ — see tmux.md
    └── dot_config/nvim/              -> ~/.config/nvim/ — see nvim.md
```

## Docs

| File | Covers |
| --- | --- |
| [chezmoi.md](chezmoi.md) | Source-state naming conventions, externals mechanism, scripts, `.chezmoiignore` matching rules |
| [capabilities.md](capabilities.md) | Capability contract, dependency/enhancement graph, ownership, and verification model |
| [tools.md](tools.md) | Every pinned host tool: version, source, target path, platform coverage |
| [nvim.md](nvim.md) | Neovim config structure, LazyVim extras, plugin files, lockfiles |
| [tmux.md](tmux.md) | tmux config structure, theme, plugin pinning |

## Invariants

- No file under `internal/`, `cmd/`, or a `Makefile`/`go.mod` — the Go CLI this repo used to ship was retired; do not recreate it.
- Everything host tools install to lives under `.local/` (Unix) or the Windows equivalents declared in `.chezmoiexternals/` — no `sudo`, no system package manager calls, no privileged services.
- Version/URL/checksum changes for a pinned tool always land together in the same commit.
