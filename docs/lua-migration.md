# Lua engine — deleted

The Lua engine is gone. `workstation/lua/` (engine, app shell, launcher) and
`packages/*/compose.lua` (factory modules) were removed; the Elixir OTP
release executes every verb in-process (`docs/elixir.md`). This page only
records the boundary decisions that survive the deletion:

- The engine is Elixir-only: zero `nvim -l` and zero `vim.system` in the
  engine path; nvim exists on hosts only as a managed capability the
  substrate provisions.
- `modules/theme/tokens.lua` and other payload Lua files are DATA
  consumed as bytes, never executed.
- `modules/editor/nvim/**` is editor runtime payload; the profile
  composition is native now (the editor capability's nix derivation,
  `modules/editor/editor.nix`) — the manifest-era engine compositor
  (`Workstation.Packages.Nvim.Profile`) retired with the format.
- Parity-anchor retention of the Lua read path was explicitly OVERRULED by
  the owner; the recorded-envelope goldens retired with the manifest
  format (docs/absorption.md) — verification is behavioral.

Historical rationale for the original Lua core is preserved in git history
(`docs/lua-migration.md` before the fusion-final lanes).
