# Workstation testing

## Offline source checks

```sh
sh .github/scripts/check.sh
```

The static battery: the nix identity gate (per-host identity lives only in
`hosts/<host>/default.nix`), the engine-free gate (the tree-wide grep for
the Elixir module token stays empty — the engine stays gone), `sh -n` +
ShellCheck over the shell surfaces, the launcher shim's dispatch gate (a
stub `nix` and a stub `workstation-switch` — dispatch, flake resolution
order, delegation and fail-closed paths, no nix install needed), the nix
eval read gate (`#workstation.report.<verb>` answers — self-skipped where
nix is absent; the docker acceptance owns it there), and
`git diff --check`. ShellCheck is required in Linux CI; report local
absence.

Verification beyond the battery is behavioral (docs/endgame.md decision 2):
structural assertions live in the eval (the report fold's integrity
checks), never as byte contracts.
Never run fixtures directly against a switched home: they write fake Node/npm state.
For bounded Linux source checks, use a cleared environment, network denial,
120-second deadline and a **4 MiB per-file** limit (`ulimit -f 4096` in a shell
using 1024-byte blocks; use the byte-equivalent setting otherwise).

Synthetic graph/composition/CLI/harness tests are not downloaded-asset,
real Pi discovery/reload or native-platform acceptance. Backend rendering requires
[a full source audit first](home-state.md#isolated-validation); dry-run is not a sandbox.

## Real integration

Real substrate integration needs nix (docker `nixos/nix:2.35.3` against a
persistent store volume works; build from `git archive HEAD` extractions —
worktree gitdirs do not resolve in containers) and explicit authorization.
The acceptance ladder, cheapest first:

- **`nix flake check`** — the canonical entry (the flake's `checks`
  output): the declared-state reads answer, every host leg still
  evaluates (toplevel drvPath — eval only, nothing builds), and the
  golden VM E2E boots and runs its live consumer smokes (tcg where KVM
  is absent; the timeout is the boot bound). Locally and in CI — one
  surface, no second entry to drift.
- **The reads answer**: `nix eval --json .#workstation.report.{status,
  plan,capabilities}` and every host leg's toplevel `drvPath` evaluates
  (CI's nix job runs exactly this on a clean checkout).
- **The closures build**: the linux home configuration's
  `activationPackage` and the VM test's system closure.
- **The VM E2E** (`tests/nix/run-vm.sh`, the `checks.<system>.vm-e2e`
  check's script): boots the NixOS VM (tcg where
  KVM is absent; the timeout is the boot bound) and runs
  `tests/nix/vm-e2e.nix` inside it — the daemonless retirement proof (no
  unit, no socket), the consumer smokes (the launcher shim dispatch, the
  nvim profile link, the language profile, the rc lane's declared order,
  the migrated tools running, the agent skills at pinned
  versions, the tmux/nunchux/foundation planes, the theme token path), the
  adopt rehearsal (a copy-contract tree makes way for the declared
  symlink), the apply-driven switch (`workstation-switch apply` over the
  offline activation override) and the switch receipt. This IS the
  fresh-host parity proof (r5 standard): a bare VM home, one apply from
  the flake, the resulting home matching the declared expectations,
  consumer-smoked end to end. Receipts land in `tests/nix/*.log`
  (gitignored).

Work in a scratch context: never a live home, never the operator's store
paths. Failures retain the build log, the VM console output and the failing
exit code. Use existing trusted prerequisites; do not download lint tools to
close a local gap. A green offline pass proves neither the eval nor the boot
ran; Linux containers do not establish native macOS arm64 or WSL acceptance.
