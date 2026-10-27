# Workstation testing

## Offline source checks

```sh
sh .github/scripts/check.sh
```

The static battery: the nix identity gate (per-host identity lives only in
`hosts/<host>/default.nix`), the tree-purity gate (the tree-wide grep for a
foreign module-system token stays empty), `sh -n` +
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
The lane map — which lane proves what:

- **The static battery** (`sh .github/scripts/check.sh`) — offline source
  gates, universal: any checkout, no nix required.
- **The eval gates** — the DECLARED surface, universal where nix runs
  (locally via the docker-nix recipe, and CI's nix jobs): `nix flake
  check` evaluates the declared-state reads, every host leg's toplevel
  (drvPath — eval only, nothing builds) and both home configurations
  (the linux leg and the e2e persona), and stages the container lane's
  entry (below). This is the system plane's ONLY gate — the NixOS/WSL
  system activation never proved itself by booting; the toplevel
  drvPath is the proof, and no VM is anywhere in it.
- **The container E2E** (`tests/nix/run-container.sh`) — the BEHAVIORAL
  surface, on any docker host (CI's `container-e2e` job runs the check's
  staged entry; a host without host-nix runs the script straight from a
  checkout). A throwaway `nixos/nix` container receives the flake source,
  builds the e2e persona's home plane and the proof driver inside, stages
  the boot home, then runs `tests/nix/e2e.nix`: the daemonless retirement
  proof (no unit, no socket), the consumer smokes (the launcher shim
  dispatch, the nvim headless boot with the languages composed — the
  composed profile.lua is a lua CHUNK, the regression the boot smoke
  owns, the lazy-lock merge, the theme token path, the language profile,
  the rc lane's declared order, the migrated tools running, the agent
  skills at pinned versions, the tmux/nunchux/foundation planes), the
  adopt rehearsal (a copy-contract tree makes way for the declared
  symlink), the retire rehearsal (a planted tombstone tree leaves
  through the declared `recursive = true` consent, verdict-receipted),
  the apply-driven switch (`workstation-switch apply` over the
  offline activation override) and the switch receipt. This IS the
  fresh-host parity proof: a bare home, one apply from the flake, the
  resulting home matching the declared expectations, consumer-smoked end
  to end. The gate: without a usable docker the lane refuses loudly with
  the named reason and the alternative — never a degraded run.
- **The closures build** — the persona's `activationPackage` realizes
  inside the container lane; the host legs' closures build where a
  builder is authorized.

Named residuals (the container lane cannot prove what a boot proved):

- A nix build cannot drive a docker daemon (the sandbox holds no daemon
  socket), so `checks.<system>.container-e2e` STAGES the lane's one entry
  (`bin/run-container-e2e` + the flake source it mounts) instead of
  running it — `nix flake check` proves the lane's whole surface
  evaluates and produces the entry; the behavioral run is the staged
  entry on a docker host. The VM check's in-derivation boot has no
  container equivalent; there is no VM lane anywhere.
- The container runs the persona proof as the container's root with the
  persona home (the nix image is single-user, no service manager): the
  service-manager probes (systemd's view of the user units) and
  user-plane separation stay real-host verify contracts; the retirement
  probe is file-plane in the container.

Work in a scratch context: never a live home, never the operator's store
paths. Failures retain the build log, the container log and the failing
exit code. Use existing trusted prerequisites; do not download lint tools to
close a local gap. A green offline pass proves neither the eval nor the
activation ran; Linux containers do not establish native macOS arm64 or WSL
acceptance.
