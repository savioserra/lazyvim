# Chezmoi file backend

The repository `chezmoi/` directory contains only managed home state. The public
interface is the repo-native `workstation/bin/workstation`, not chezmoi commands.
`workstation/versions.json` owns the backend pin; no `.chezmoiversion` policy,
source-root marker, archive externals or lifecycle run-after scripts remain.

## Lifecycle and file ownership

```text
bootstrap -> pinned Neovim -> pinned chezmoi -> public launcher link
apply     -> owned real-account legacy service retirement (never scratch)
          -> chezmoi --source <repo>/chezmoi --destination <target-home> apply
          -> refresh materialized Node pin/PATH -> package setup
sync      -> mutable application state restoration
verify    -> version and behavior checks
update    -> checked git pull --ff-only -> freshly pulled launcher bootstrap
          -> freshly launched apply -> sync -> verify (first failure stops)
```

`workstation diff` previews file-backend state only. It ensures the pinned backend
is available; it does not simulate setup or sync. Setup owns host downloads and
configuration. Bootstrap owns Neovim, backend and launcher installation, not
chezmoi. Authentication, sessions and provider state remain user-owned.

## Source naming

| Source | Target/behavior |
| --- | --- |
| `dot_<name>` | `~/.<name>` |
| `executable_<name>` | Executable target |
| `symlink_<name>[.tmpl]` | Symlink; contents are the target |
| `modify_<name>.tmpl` | File content modifier, not lifecycle orchestration |
| `.chezmoiignore` | Repository-only `AGENTS.md` exclusions |
| `.chezmoiremove` | Explicit stale-file removals |

Use actual nested directories. Templates select `.chezmoi.os` (`linux`/`darwin`),
`.chezmoi.arch` (`amd64`/`arm64`) and `.chezmoi.destDir`. WSL uses Linux; native
Windows is unsupported. Removed non-exact targets need `.chezmoiremove` entries;
package-owned exact archive trees are pruned by provisioning instead.

Shell modifiers print literal environment/auth snippets; rendering them does not
source login profiles or read `/etc/pi/op.env` or `/etc/ntfy/notifier.env`.
Those files and their credentials remain operator-owned (see `secrets.md`).

## Isolated validation

Public preview: `workstation diff`. A file-only structural probe may invoke the
backend directly with explicit source, destination, config, persistent state and
cache in isolated roots. For example, after bootstrap, with a newly created
scratch parent outside home/source and a known absolute backend path:

```sh
scratch=$(mktemp -d)
mkdir "$scratch/home" "$scratch/config" "$scratch/cache" "$scratch/state" "$scratch/tmp"
printf '{}\n' > "$scratch/config/chezmoi.json"
env -i PATH=/usr/bin:/bin HOME="$scratch/home" TMPDIR="$scratch/tmp" \
  XDG_CONFIG_HOME="$scratch/config" XDG_DATA_HOME="$scratch/state" \
  XDG_STATE_HOME="$scratch/state" XDG_CACHE_HOME="$scratch/cache" \
  "$HOME/.local/opt/chezmoi/bin/chezmoi" \
  --source "$PWD/chezmoi" --destination "$scratch/home" \
  --config "$scratch/config/chezmoi.json" --config-format json \
  --cache "$scratch/cache/chezmoi" --persistent-state "$scratch/state/chezmoi.boltdb" \
  --no-pager --no-tty apply --dry-run
```

Audit all templates/modifiers before executing a backend probe; dry-run or
`--exclude` alone is not a sandbox. The bounded Linux phase5 structural gate uses
network denial, timeout 120 seconds and `ulimit -f 4096`, with the **existing
2.72.0 backend**, not installation or acceptance of canonical **2.72.1**. Exact
pinned backend, real assets and full native lifecycle validation remain separate.

For real integration use `.github/scripts/test-apply.sh <new-absolute-home>`.
It refuses existing paths (even empty ones), home/source or their ancestors and
descendants, claims the new directory atomically, and never deletes caller input.
An `env -i` child uses fixed Unix/Homebrew prerequisite PATH, private writable
roots and disabled ambient Git config. No actual login profiles are loaded.
Bootstrap installs prerequisites before public-link apply/sync; all Lua suites,
syntax/projection/shell/format checks run before public verify. Failures propagate
the exact failing exit code and retain scratch evidence. Offline harness tests
copy the source and substitute local lifecycle fakes; real nonrecursive suites
also run through the actual checker against a synthetic populated parent home.
The checker freezes absolute installed Neovim/Mason StyLua paths before each
suite gets a fresh private HOME/TMP/XDG/cache and cleared environment through
`test-home.sh`. Owned `/tmp/workstation-test.*` roots are printed and retained
for inspection, independent of caller-selected writable roots and never recursively deleted.
Bootstrap fixtures adapt both simulated host hash commands over one available
`sha256sum` or `shasum`; no cross-platform hash dependency is added. This is not
a real install or native-platform acceptance.

## Breaking cutover

This is an **operator/parent procedure**, not an automatic migration script.
Do not execute it while agents are working in `/root/lazyvim` or any active source
checkout. Publication and live cutover require separate approval and platform gates.

1. Inspect `~/.local/share/workstation` and `~/.local/bin/workstation` without
   following unknown links. Determine whether the former is the old deployed
   `apps/`, `lua/`, `packages/`, `versions.json` payload, a real Git clone with
   sibling `workstation/` and `chezmoi/`, or user-owned data. Record exact paths,
   Git HEAD/status if applicable, launcher target, ownership and rollback location.
   Stop on ambiguity; do not clone into an existing directory or delete it.
2. After workers stop, back up approved legacy payload/files to a **new, absent,
   operator-chosen sibling path** using a guarded rename. Back up the old launcher
   separately if conflicting. Never recursively remove an engine directory,
   overwrite a backup, or move the active `/root/lazyvim` checkout as part of this
   procedure. User files, secrets and session state are not engine cleanup targets.
3. Clone the whole repository into the now-absent destination, or choose another
   absent checkout path. Inspect the clone and pins before running its launcher
   bootstrap. Bootstrap refuses a link to another checkout; explicitly back up
   and remove/repoint only the inspected old link before retrying. A matching
   managed link is left unchanged. Runtime/backend bootstrap must succeed first.
4. Review `workstation diff`, then approve real apply, sync and verify separately.
   Only real-account apply may retire the identified owned legacy service before
   file removal; scratch never contacts the live user manager. Missing or unsafe
   service/session ownership fails closed rather than claiming retirement.
5. On failure stop. Preserve logs and both checkouts/backups. To roll back the
   launcher, inspect its current target and replace **only that approved link**
   with the recorded previous target. Restore approved legacy paths from their
   backups only into absent destinations after checking for new state; never
   erase the new clone to make room. Restoring a launcher/source does not undo
   already changed home files, installed tools or retired service state: those
   need reviewed backups and explicit operator recovery. No automatic rollback
   may touch authentication or resume a service.

`.chezmoiremove` removes the old temporary bridge only at
`.local/share/workstation/versions.json`, **not** the clone root or its canonical
`workstation/versions.json`. Other legacy engine payload inspection/cleanup is
operator-owned; there is no blanket recursive migration deletion. Historical
Backlog/decision references to `home/`, `.chezmoiroot`, externals and scripts
explain the previous layout and are not current instructions.
