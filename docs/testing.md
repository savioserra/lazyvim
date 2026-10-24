# Workstation testing

## Offline source checks

```sh
sh .github/scripts/check.sh
```

The fused engine's matrix is Elixir-native: the
nix identity gate (per-host identity lives only in
`hosts/<host>/default.nix`), the full
`mix test` suite (hermetic fixture homes, no host state touched), `sh -n`
+ ShellCheck
over the remaining shell scripts, the UTF-8 locale guard gate over the POSIX
shim (stubbed `locale`, stub release; no tarball needed), the release boot
smoke when a local release tarball is built, and `git diff --check`.
ShellCheck is required in Linux CI; report local absence.

The retired Lua suites, the `nvim -l` syntax pass and StyLua died with the Lua
engine; the recorded-envelope goldens and their replay contract retired with
the manifest format they pinned (docs/absorption.md — verification is
behavioral).
Never run fixtures directly against a switched home: they write fake Node/npm state.
For bounded Linux source checks, use a cleared environment, network denial,
120-second deadline and a **4 MiB per-file** limit (`ulimit -f 4096` in a shell
using 1024-byte blocks; use the byte-equivalent setting otherwise).

Synthetic graph/composition/CLI/harness tests are not downloaded-asset,
real Pi discovery/reload or native-platform acceptance. Backend rendering requires
[a full source audit first](home-state.md#isolated-validation); dry-run is not a sandbox.

## Real integration

Real substrate integration needs nix and explicit authorization:

- build the flake's package set (`packages.<system>.workstation` builds the
  engine release — the mixRelease with the vendored NIFs, digest-gated by
  `nix/engine.nix`'s preConfigure check);
- boot the NixOS VM test (`tests/nix`): it proves the daemon user unit and
  the switch seam end to end, and smokes the engine's read verbs against
  the baked report.

Work in a scratch context: never a live home, never the operator's store
paths. Failures retain the build log, the VM console output and the failing
exit code. Use existing trusted prerequisites; do not download lint tools to
close a local gap. A green offline pass proves neither the eval nor the boot
ran; Linux containers do not establish native macOS arm64 or WSL acceptance.
