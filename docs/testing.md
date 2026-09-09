# Workstation testing

## Offline source checks

```sh
sh .github/scripts/check.sh
```

Requires installed pinned Neovim and locked Mason StyLua (available after sync).
The runner freezes their absolute paths, then `test-home.sh` gives each suite/check
fresh private HOME/WORKSTATION_HOME, TMP, XDG and cache with cleared ambient state.
Only prerequisite PATH is retained, not auth/agent/session/tool configuration.
Never run fixtures directly against an applied home: they write fake Node/npm state.
Owned 0700 `/tmp/workstation-test.*` roots are printed and retained for inspection;
no caller path is recursively deleted. Fixture umask is 022 inside that boundary.

The checker runs all `tests/*.test.lua` (graph/profile, provider contract,
journal/preconditions, real backend renders, provisioning, CLI/update/launcher,
cold bootstrap, package parity, checker/harness regressions), Lua/JSON syntax,
generated pin projection, StyLua, each shell file separately with `sh -n` and
available ShellCheck, then `git diff --check`. ShellCheck is required in Linux
CI; report local absence. The real-render suite needs a trusted installed
backend: the canonical pinned path wins, otherwise a retained evidence
extraction (for example `~/.local/opt/chezmoi-2.72.0/chezmoi`) is used and its
ACTUAL version is reported by the suite — existing-2.72.0 renders are file
semantics evidence, never pinned-2.72.1 lifecycle acceptance.
For bounded Linux source checks, use a cleared environment, network denial,
120-second deadline and a **4 MiB per-file** limit (`ulimit -f 4096` in a shell
using 1024-byte blocks; use the byte-equivalent setting otherwise).

Synthetic graph/provisioning/bootstrap/CLI/harness tests are not downloaded-asset,
real Pi discovery/reload or native-platform acceptance. Backend rendering requires
[a full source audit first](chezmoi.md#isolated-validation); dry-run is not a sandbox.

## Real integration

With explicit network/installation authorization, `.github/scripts/test-apply.sh
<new-absolute-home>` runs bootstrap → public apply → sync → checks → public verify.
The target must be absent and outside the real home/source (not their ancestor or
descendant). The harness claims it atomically, clears ambient environment/Git
configuration, uses private writable roots and never loads login profiles or
`/etc` auth snippets. Failures retain scratch evidence and the failing exit code.
Use existing trusted prerequisites; do not download lint tools to close a local gap.

## Linux container E2E recipe

[`.github/Dockerfile.e2e`](../.github/Dockerfile.e2e) wraps the unchanged harness.
Build and execution require separate approval. A recipe/offline pass proves neither
ran; Linux containers do not establish native macOS arm64 or WSL acceptance.

### Base provenance

The `FROM` pin is the official Ubuntu 24.04 `linux/amd64` manifest SHA256
`1e0a86e57d247923571b75e0aaf48a1449cf8c543d51fb3e07a4a7d7bfa79316`.
Public [manifest metadata](https://registry-1.docker.io/v2/library/ubuntu/manifests/24.04)
and resolution receipts are retained in TASK-34 notes/Git history. Apt is limited
to image-local unmanaged OS/build/font/shell prerequisites (repository versions
are unpinned); no managed runtimes/apps, user caches or credentials are baked in.

### Build context and runtime contract

- Prepare an independent Git clone of the reviewed commit with sanitized Git
  settings and `clone --no-local --no-hardlinks --template=`. Remove local origin;
  confirm exact HEAD, clean tracked/untracked status, no alternates or hardlinked
  objects. Include `.git` for the checker. Never send the working checkout, root
  home, untracked `.pi`, auth files or ambient Docker/Git configuration. Build only
  this context with `--platform=linux/amd64 -f .github/Dockerfile.e2e`.
- Use image UID/GID 10001, HOME `/caller`, and a read-only rootfs including the
  account-owned `/source`; no writable source overlay. Fixture copies may be
  edited only in private scratch space.
- Supply a fresh labeled test-only `/work` volume (initialized to 10001:10001) and
  **private, bounded, executable `/tmp` tmpfs**: fixtures execute shims there, so
  `noexec` is invalid. Keep `nosuid,nodev`; record actual mount flags. `/work/home`
  must be absent and distinct from `/caller`. Retain volume/first-failure receipts;
  no `--rm`, automatic retries or broad cleanup.
- Drop all capabilities, set no-new-privileges; bound CPU, memory, PIDs, per-file
  size (2 GiB) and wall time (25 minutes with kill escalation). Use private network
  and PID namespaces. No privileged mode, host networking, published ports, host
  sockets/directory mounts, auth/session environment, service/daemon changes,
  model/vault/account probes or sourced login profiles.
- Retain commands, image/source IDs, identity/isolation/mount/limit receipts,
  stdout/stderr and exits. Stop at first failure. Only after full success, validate
  cached public bootstrap in a **separate network-none** container with the retained
  volume and same immutable source.
