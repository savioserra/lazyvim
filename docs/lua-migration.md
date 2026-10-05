# Lua engine — deleted

The Lua engine is gone. `workstation/lua/` (engine, app shell, launcher) and
`packages/*/compose.lua` (factory modules) were removed; the Elixir OTP
release executes every verb in-process (`docs/elixir.md`). This page only
records the boundary decisions that survive the deletion:

- The engine is Elixir-only: zero `nvim -l` and zero `vim.system` in the
  engine path; nvim exists on hosts only as a managed capability installed
  at bootstrap.
- `packages/theme/tokens.lua` and other package payload Lua files are DATA
  consumed as bytes (chezmoi token envelopes), never executed.
- `packages/nvim/**` is editor runtime payload; the profile composition
  contract it mirrors lives in `Workstation.Core.Source.NvimProfile`.
- Parity-anchor retention of the Lua read path was explicitly OVERRULED by
  the owner; the golden envelopes under `tests/goldens/` remain the
  canonical cross-engine contract and are graded by `mix workstation.goldens`.

Historical rationale for the original Lua core is preserved in git history
(`docs/lua-migration.md` before the fusion-final lanes).
