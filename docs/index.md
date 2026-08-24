# Repository map

chezmoi-managed Neovim + tmux configuration for Linux, macOS, Windows. No build step or compiled wrapper CLI; `sync` and `sync.ps1` are small native orchestration scripts.

## Layout

```
.
├── README.md                    human install/workflow doc
├── sync                         Bash update/apply/restore workflow
├── docs/                        this directory
├── .github/workflows/ci.yml     applies into a scratch HOME per platform
├── .github/workflows/release.yml publishes checksummed archives for v* tags
└── home/                        chezmoi source state (.chezmoiroot = "home")
    ├── .chezmoiversion            pinned chezmoi version
    ├── .chezmoiexternal.toml.tmpl  pinned host-tool downloads — see tools.md
    ├── .chezmoiscripts/            run_onchange_ scripts — see chezmoi.md
    ├── .chezmoiignore              platform-conditional exclusions
    ├── dot_local/bin/               -> ~/.local/bin
    ├── dot_tmux.conf                -> ~/.tmux.conf — see tmux.md
    ├── dot_config/tmux/themes/      -> ~/.config/tmux/themes/ — see tmux.md
    └── dot_config/nvim/              -> ~/.config/nvim/ — see nvim.md
```

## Docs

| File | Covers |
| --- | --- |
| [chezmoi.md](chezmoi.md) | Source-state naming conventions, externals mechanism, scripts, `.chezmoiignore` matching rules |
| [tools.md](tools.md) | Every pinned host tool: version, source, target path, platform coverage |
| [nvim.md](nvim.md) | Neovim config structure, LazyVim extras, plugin files, lockfiles |
| [tmux.md](tmux.md) | tmux config structure, theme, plugin pinning |

## Invariants

- No file under `internal/`, `cmd/`, or a `Makefile`/`go.mod` — the Go CLI this repo used to ship was retired; do not recreate it.
- Everything host tools install to lives under `.local/` (Unix) or the Windows equivalents in `.chezmoiexternal.toml.tmpl` — no `sudo`, no system package manager calls, no privileged services. Tools that require that (system daemons, root install) are documented as manual steps in README.md, not automated here.
- Version/URL/checksum changes for a pinned tool always land together in the same commit.
