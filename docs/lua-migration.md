# ADR: lifecycle runtime

| Field | Value |
| --- | --- |
| Status | Accepted |
| Runtime | Checksum-pinned Neovim |
| Entry point | `nvim -l run.lua <setup|sync|verify>` |
| User config loaded by parent | No |
| Configured editor processes | Spawned by Neovim feature child dispatcher |
| Bootstrap dependency | Chezmoi-installed Neovim |
| Node role | Managed capability; not a runtime dependency |

## Constraints

- The runtime must exist before post-apply scripts execute.
- Setup must work before Node environment configuration.
- One Lua implementation must run on all supported hosts.
- Editor behavior checks require configured Neovim child processes.

## Execution sequence

```text
chezmoi externals
  -> pinned Neovim
  -> run.lua setup
  -> run.lua sync
  -> run.lua verify
```

## Runtime layout

```text
dot_local/share/lazyvim/
├── run.lua
├── versions.json
└── lua/setup/
    ├── app.lua
    ├── capabilities/
    ├── runtime/
    ├── features/
    ├── host/
    └── platforms/
```

## Rejected runtime dependency

| Option | Reason |
| --- | --- |
| Managed Node | Circular bootstrap: Node setup would require Node |
| System Lua | Not consistently present or versioned across hosts |
| Per-platform orchestration scripts | Duplicates lifecycle and verification behavior |

## External references

- [Neovim `-l`](https://neovim.io/doc/user/starting/)
- [Neovim Lua modules](https://neovim.io/doc/user/lua/)
- [lazy.nvim spec structure](https://lazy.folke.io/usage/structuring)
