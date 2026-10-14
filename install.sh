#!/bin/sh
# Workstation quickstart installer: acquire the pinned mise toolchain manager,
# provision the first-acquisition tool pins, clone the repository, bootstrap
# the engine, apply, sync and verify. This is the guarded fresh-install
# sequence from README.md ("Fresh installation") encoded as one command:
#
#	curl -fsSL https://raw.githubusercontent.com/savioserra/lazyvim/main/install.sh | sh
#
# mise-first chain: the shell pins mise (version + SHA-256 from the cloned
# checkout's workstation/versions.json), mise provides the first-acquisition
# tool pins (tmux, btop on Linux — skipped on darwin, where they are host
# prerequisites; the skip is stated in the banner — then the pinned
# Erlang/Elixir toolchain the release build resolves), and the engine
# bootstrap works unchanged from there. Every mise resolution in the chain
# is scoped to the checkout's own pins: the ambient global config/conf.d is
# isolated out, so a stale linux-only pin can never abort a darwin install.
# These shell-level pins are first acquisition only: steady-state management
# of the tools belongs to the engine's mise contract.
#
# Host prerequisites: POSIX shell, curl, git and the ordinary archive/hash
# tools (tar/gzip, sha256sum or shasum). On Linux git is the single distro
# prerequisite (`apt install git` — no reputable first-party static git
# artifact exists to pin; see docs/tools.md); macOS ships git with the
# Command Line Tools. Everything lives under $HOME: the script never needs
# root. It refuses to touch an existing checkout, which may be the old
# deployed engine payload (see docs/chezmoi.md "breaking cutover").
set -eu

REPO_URL=${WORKSTATION_REPO:-https://github.com/savioserra/lazyvim.git}
REF=${WORKSTATION_REF:-}
DEST=${WORKSTATION_DEST:-"${HOME:-}/.local/share/workstation"}

say() { printf 'install: %s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

[ -n "${HOME:-}" ] || die 'HOME is not set; a user home is required'
command -v git >/dev/null 2>&1 || die 'git is required; on Linux: apt install git (the single distro prerequisite — see docs/tools.md)'
command -v curl >/dev/null 2>&1 || die 'curl is required (https://curl.se)'

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
versions=$DEST/workstation/versions.json
[ -f "$versions" ] || die 'engine checkout lacks workstation/versions.json'

case "$(uname -s)/$(uname -m)" in
Linux/x86_64) platform=linux_x86_64 ;;
Darwin/arm64) platform=darwin_arm64 ;;
*) die 'supported hosts are Linux x86_64 (including WSL) and Darwin arm64' ;;
esac

hash() {
	if [ "$platform" = darwin_arm64 ]; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d ' ' -f 1
}
valid_hash() {
	[ "${#1}" -eq 64 ] || return 1
	case "$1" in *[!0-9a-f]*) return 1 ;; esac
}
# Bounded field extraction from the canonical engine-owned versions.json —
# the same fail-closed one-anchored-match rule the runtime installer uses:
# a parse miss (missing, duplicated, or non-plain-string field) never guesses.
json_string() {
	_key=$1
	[ "$(grep -c "^[[:space:]]*\"$_key\"[[:space:]]*:" "$versions" || true)" = 1 ] \
		|| die "versions.json: $_key missing or duplicated"
	_value=$(sed -n "s/^[[:space:]]*\"$_key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\"[[:space:]]*,\{0,1\}[[:space:]]*\$/\1/p" "$versions")
	[ -n "$_value" ] || die "versions.json: $_key is not a plain string"
	printf '%s\n' "$_value"
}

# --- mise acquisition (checksum-pinned; fail closed) ----------------------
mise_version=$(json_string mise)
case "$mise_version" in ''|*[!0-9.]*) die 'invalid mise version' ;; esac
case "$platform" in
linux_x86_64) mise_key=linux_x86_64 mise_suffix=linux-x64 ;;
darwin_arm64) mise_key=darwin_arm64 mise_suffix=macos-arm64 ;;
esac
mise_url=$(json_string "mise_${mise_key}_url")
mise_digest=$(json_string "mise_${mise_key}_sha256")
# POSIX has no global ${var//}; the version is validated digits/dots first,
# so the sed program carries no metacharacters.
mise_url=$(printf '%s' "$mise_url" | sed "s/{V}/$mise_version/g")
case "$mise_url" in
"https://github.com/jdx/mise/releases/download/v$mise_version/mise-v$mise_version-$mise_suffix.tar.gz") ;;
*) die 'invalid mise URL' ;;
esac
case "$mise_url" in *[!a-zA-Z0-9./:_-]*) die 'invalid mise URL characters' ;; esac
valid_hash "$mise_digest" || die 'invalid mise manifest record'
if [ -e "$HOME/.local/bin/mise" ] || [ -L "$HOME/.local/bin/mise" ]; then
	die "$HOME/.local/bin/mise already exists; install.sh never replaces an existing mise"
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/workstation-install.XXXXXX")
cleanup() { rm -rf "$tmp"; }
trap cleanup 0
trap 'exit 1' 1 2 15

say "acquiring mise $mise_version (checksum-pinned)"
curl --proto '=https' --proto-redir '=https' -fSL --retry 3 -o "$tmp/mise.tar.gz" "$mise_url"
[ "$(hash "$tmp/mise.tar.gz")" = "$mise_digest" ] || die 'mise checksum mismatch'
# Reject traversal before extraction. Release archives have one owned root.
tar -tf "$tmp/mise.tar.gz" > "$tmp/members"
while IFS= read -r name; do
	case "$name" in /*|../*|*/../*|*/..|..) die 'unsafe mise archive member' ;; esac
done < "$tmp/members"
tar -xzf "$tmp/mise.tar.gz" -C "$tmp"
if ! { [ -x "$tmp/mise/bin/mise" ] && [ ! -L "$tmp/mise/bin/mise" ]; }; then die 'mise archive lacks executable bin/mise'; fi
mkdir -p "$HOME/.local/bin"
cp "$tmp/mise/bin/mise" "$HOME/.local/bin/mise"
chmod 0755 "$HOME/.local/bin/mise"
mise_actual=$("$HOME/.local/bin/mise" --version)
case "$mise_actual" in "$mise_version "*) ;; *) die 'mise version mismatch' ;; esac

PATH="$HOME/.local/bin:$PATH"
export PATH

# --- first-acquisition tool pins (Linux; macOS keeps host tmux/btop) ------
if [ "$platform" = linux_x86_64 ]; then
	tmux_version=$(json_string tmux)
	tmux_backend=$(json_string tmux_mise_backend)
	btop_version=$(json_string btop)
	btop_backend=$(json_string btop_mise_backend)
	case "$tmux_version$btop_version" in ''|*[!0-9a-z.]*) die 'invalid mise tool pin version' ;; esac
	case "$tmux_backend" in aqua:*|github:*) ;; *) die 'invalid tmux mise backend' ;; esac
	case "$btop_backend" in aqua:*|github:*) ;; *) die 'invalid btop mise backend' ;; esac
	case "$tmux_backend$btop_backend" in *[!a-z0-9:/._-]*) die 'invalid mise backend characters' ;; esac
	say "provisioning $tmux_backend@$tmux_version and $btop_backend@$btop_version via mise"
	mise install "$tmux_backend@$tmux_version" "$btop_backend@$btop_version"
	# The activation record: a workstation-namespaced fragment mise merges
	# beside the engine-managed config.toml, so the tools resolve in activated
	# shells without any managed-payload change.
	conf_dir=$HOME/.config/mise/conf.d
	mkdir -p "$conf_dir"
	{
		printf '# Written by the workstation installer: first-acquisition tool pins.\n'
		printf '# Steady-state declarations belong to the engine mise contract.\n'
		printf '[tools]\n'
		printf '"%s" = "%s"\n' "$tmux_backend" "$tmux_version"
		printf '"%s" = "%s"\n' "$btop_backend" "$btop_version"
	} > "$conf_dir/workstation-bootstrap.toml"
	tmux_actual=$(mise exec "$tmux_backend@$tmux_version" -- tmux -V)
	case "$tmux_actual" in "tmux $tmux_version") ;; *) die 'tmux version mismatch' ;; esac
	btop_actual=$(mise exec "$btop_backend@$btop_version" -- btop --version)
	# The btop banner may arrive colorized; anchor both ends of the version
	# line instead of assuming a plain prefix.
	case "$btop_actual" in *"btop version: "*"$btop_version"*) ;; *) die 'btop version mismatch' ;; esac
	# The engine's verify starts an isolated tmux server; the shims carry the
	# freshly provisioned tools through the rest of this install chain.
	case ":$PATH:" in
	*":$HOME/.local/share/mise/shims:"*) ;;
	*) PATH="$HOME/.local/share/mise/shims:$PATH" ;;
	esac
	export PATH
else
	say 'tmux/btop pins skipped on darwin: host prerequisites (brew); provisioning the toolchain pins only'
fi

# The pinned Erlang/Elixir toolchain from the checkout's .tool-versions — the
# same pins the release build resolves. The erlang/elixir mise backends clone
# through git, which is why the git prerequisite precedes this step. The
# resolution is scoped to exactly those checkout pins: the ambient global
# config/conf.d never enters this install — a stale engine-managed config.toml
# (composed before the platform-scope contract) can still declare the
# linux-only tmux/btop pins, and a bare `mise install` provisions every
# declared tool, aborting darwin ("No matching asset found for platform
# macos-arm64"). The empty MISE_CONFIG_DIR drops that slot from the chain;
# the release build (bootstrap/install-runtime.sh) applies the same isolation.
say 'installing the pinned elixir/erlang toolchain via mise'
toolchain_config=$tmp/mise-config
mkdir "$toolchain_config"
(cd "$DEST" && MISE_CONFIG_DIR="$toolchain_config" mise install)

# Interactive verbs render the TUI on a terminal and hard-error without one,
# so a piped run (curl | sh) must pass --headless explicitly. Only bootstrap
# and apply have TUI/plain dispatch; sync and verify are always plain.
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
"$bin" sync
say 'verifying installed versions and behavior'
"$bin" verify

say 'done: workstation is installed, applied and verified'
case ":${PATH}:" in
*":${HOME}/.local/bin:"*) ;;
*) say "add ~/.local/bin to your PATH to run 'workstation' directly" ;;
esac
