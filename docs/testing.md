# Workstation testing

## Offline source checks

Run `sh .github/scripts/check.sh` after sync. It freezes installed Neovim and
Mason StyLua, then gives every suite/check private HOME/TMP/XDG/cache roots via
`test-home.sh`; never run fresh-home fixture suites against an applied home.
For bounded Linux repair checks, additionally use a cleared environment,
network denial, a 120-second deadline and `ulimit -f 4096`. These synthetic
checks are not downloaded-asset or native-platform acceptance.

`tests/provision.test.lua` exercises real synthetic tar extraction with
`LC_ALL=C`: GNU/BSD tar display high bytes as octal escapes, not literal member
backslashes. Provisioning normalizes only those non-ASCII display octets before
unchanged path guards; real backslashes, ASCII escapes, absolute paths and `..`
components remain rejected. ZIP listings and caller `inner_path` stay literal.
Link confinement, checksum, mode, staging, overlay and rollback checks still
apply. No locale installation, shell unquoting or extra bootstrap runtime is needed.

## Linux container E2E recipe

`.github/Dockerfile.e2e` wraps the **unchanged** `.github/scripts/test-apply.sh`:
bootstrap → public apply → sync → fast checks → public verify. Docker is the
Linux E2E isolation boundary, not a replacement lifecycle or public CLI. Image
build and real integration require separate authorization; a recipe or offline
fixture pass is not evidence that either ran. Native macOS arm64 CI stays in
`.github/workflows/ci.yml`; this image cannot establish macOS or WSL acceptance.

### Base provenance

The official Docker Hub `library/ubuntu:24.04` public manifest metadata resolved
on 2026-09-09 to:

| Metadata | SHA256 |
| --- | --- |
| OCI index (`registry-1.docker.io/v2/library/ubuntu/manifests/24.04`) | `33ceb71981b602c1a7443a53469e4dba065f7503eab3078a2d7a57a2ab987517` |
| Selected `linux/amd64` manifest (the `FROM` pin) | `1e0a86e57d247923571b75e0aaf48a1449cf8c543d51fb3e07a4a7d7bfa79316` |

Both response body hashes match their `Docker-Content-Digest` headers. The index
identifies Ubuntu 24.04, official source `https://git.launchpad.net/cloud-images/+oci/ubuntu-base`,
revision `461fbe29535e51d03451ae146a90f730671d950d`. Metadata resolution does not
pull image layers. Apt is confined to this test image's unmanaged OS/build/font/
shell prerequisites; their repository versions are not pinned. No Node, Neovim,
Go, backend, managed apps, user caches or credentials are baked in.

### Build context and runtime contract

- Prepare a new independent Git clone of the reviewed commit using sanitized Git
  settings and `clone --no-local --no-hardlinks --template=`. Remove its local
  origin, confirm exact HEAD and clean tracked/untracked status, no alternates or
  hardlinked objects. Include `.git` for the actual checker's Git diff check.
  Never send the working checkout, root home, untracked `.pi`, auth files or
  ambient Docker/Git configuration as context. After approval build **only** this
  prepared context with `--platform=linux/amd64 -f .github/Dockerfile.e2e`.
- The stable image account is UID/GID 10001, HOME `/caller`; `/source` is owned by
  that account for Git checks. Runtime **must** use a read-only rootfs (including
  `/source`); do not mask it with a writable mount. Its ordinary source modes
  allow fixture copies to be edited only in private writable scratch space.
- Supply a new, labeled test-only volume at `/work` (image directory ownership
  initializes it to 10001:10001) and private bounded `/tmp` tmpfs. `/work/home`
  must not exist: the harness claims it. Caller-home `/caller` and target-home
  `/work/home` are deliberately distinct. Retain the volume and first-failure
  receipts, not `--rm`, automatic retries or broad cleanup.
- Drop all capabilities, set no-new-privileges, and bound CPU, memory, PIDs,
  per-file size (2 GiB) and wall time (25 minutes with kill escalation). Use
  private network/PID namespaces: no privileged mode, host networking, published
  ports, host sockets, auth/session environment, service/daemon changes or host
  directory mounts. No model/vault/account probes or sourced login profiles.
- Retain exact commands, image/source IDs, identity/isolation/limit receipts,
  stdout/stderr and exits. Stop at the first failure. Only after a successful
  full run, validate cached public bootstrap in a **separate network-none**
  container using the retained test volume and the same immutable source.
