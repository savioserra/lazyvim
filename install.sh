#!/bin/sh
# Workstation quickstart installer: clone the repository, bootstrap the engine,
# apply, sync and verify. This is the guarded fresh-install sequence from
# README.md ("Fresh installation") encoded as one command:
#
#	curl -fsSL https://raw.githubusercontent.com/savioserra/lazyvim/main/install.sh | sh
#
# Overrides: WORKSTATION_REPO (clone URL), WORKSTATION_REF (branch or tag),
# WORKSTATION_DEST (checkout location). The script never needs root: everything
# lives under $HOME. It refuses to touch an existing checkout, which may be the
# old deployed engine payload (see docs/chezmoi.md "breaking cutover").
set -eu

REPO_URL=${WORKSTATION_REPO:-https://github.com/savioserra/lazyvim.git}
REF=${WORKSTATION_REF:-}
DEST=${WORKSTATION_DEST:-"${HOME:-}/.local/share/workstation"}

say() { printf 'install: %s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

[ -n "${HOME:-}" ] || die 'HOME is not set; a user home is required'
command -v git >/dev/null 2>&1 || die 'git is required (https://git-scm.com)'

case "$DEST" in
/*) ;;
*) die "WORKSTATION_DEST must be an absolute path: $DEST" ;;
esac
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
	die "$DEST already exists; it may be the old deployed engine payload.
install: do not clone over it — follow the guarded cutover procedure in
install: docs/chezmoi.md (breaking cutover) with the operator instead."
fi

mkdir -p "$(dirname "$DEST")"

say "cloning $REPO_URL into $DEST"
if [ -n "$REF" ]; then
	git clone --branch "$REF" "$REPO_URL" "$DEST"
else
	git clone "$REPO_URL" "$DEST"
fi

launcher=$DEST/workstation/bin/workstation
[ -x "$launcher" ] || die "launcher missing or not executable: $launcher"

# Interactive verbs render the TUI on a terminal and hard-error without one,
# so a piped run (curl | sh) must pass --headless explicitly.
verb() {
	if [ -t 1 ]; then
		"$1" "$2"
	else
		"$1" "$2" --headless
	fi
}

say 'bootstrapping: managed tool pins, chezmoi backend, engine release'
verb "$launcher" bootstrap

bin=${HOME}/.local/bin/workstation
[ -x "$bin" ] || die "expected launcher after bootstrap: $bin"

say 'applying managed files'
verb "$bin" apply
say 'restoring mutable application state'
verb "$bin" sync
say 'verifying installed versions and behavior'
verb "$bin" verify

say 'done: workstation is installed, applied and verified'
case ":${PATH}:" in
*":${HOME}/.local/bin:"*) ;;
*) say "add ~/.local/bin to your PATH to run 'workstation' directly" ;;
esac
