#!/bin/sh
# Minimal POSIX runtime installer. The download pins are DERIVED from the
# checkout's versions.json — the single source of truth; there is no pins
# manifest. The engine-driven refresh passes the derived records as env.
set -eu
root=$1
platform=$2
fail() { echo "workstation bootstrap: $*" >&2; exit 1; }
case "$platform" in linux_x86_64|darwin_arm64) ;; *) fail 'unsupported platform' ;; esac
hash() {
	if [ "$platform" = darwin_arm64 ]; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d ' ' -f 1
}
valid_hash() {
	[ "${#1}" -eq 64 ] || return 1
	case "$1" in *[!0-9a-f]*) return 1 ;; esac
}
# Record validation, field by field the engine's derivation: version
# digits/dots only, URL pinned to the pinned version's GitHub release path
# with the restricted character set, 64-hex digest. Fail closed.
validate_record() {
	# $1=version $2=url $3=digest
	case "$1" in ''|*[!0-9.]*) fail 'invalid runtime version' ;; esac
	case "$2" in https://github.com/neovim/neovim/releases/download/v"$1"/nvim-*.tar.gz) ;; *) fail 'invalid runtime URL' ;; esac
	case "$2" in *[!a-zA-Z0-9./:_-]*) fail 'invalid URL characters' ;; esac
	valid_hash "$3" || fail 'invalid manifest record'
}
# Bounded field extraction for the fresh-machine path: the engine-owned
# versions.json is canonical JSON (one quoted member per line), so exactly
# one anchored match per field is enough to EXTRACT — the record
# validations are the integrity gate, and any parse miss (missing,
# duplicated, or non-plain-string field) fails closed.
json_string() {
	_key=$1
	[ "$(grep -c "^[[:space:]]*\"$_key\"[[:space:]]*:" "$root/versions.json" || true)" = 1 ] \
		|| fail "versions.json: $_key missing or duplicated"
	_value=$(sed -n "s/^[[:space:]]*\"$_key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\"[[:space:]]*,\{0,1\}[[:space:]]*\$/\1/p" "$root/versions.json")
	[ -n "$_value" ] || fail "versions.json: $_key is not a plain string"
	printf '%s\n' "$_value"
}
version=${NEOVIM_VERSION-}
linux_url=${NEOVIM_LINUX_X86_64_URL-}
linux_digest=${NEOVIM_LINUX_X86_64_SHA256-}
darwin_url=${NEOVIM_DARWIN_ARM64_URL-}
darwin_digest=${NEOVIM_DARWIN_ARM64_SHA256-}
if [ -n "$version" ]; then
	# Engine-driven refresh: the daemon derived both records from the same
	# checkout's versions.json and handed them over; an incomplete env is a
	# loud failure, never a partial pin.
	if [ -z "$linux_url" ] || [ -z "$linux_digest" ] || [ -z "$darwin_url" ] || [ -z "$darwin_digest" ]; then
		fail 'engine pin env incomplete: NEOVIM_VERSION and the four NEOVIM_<PLAT>_URL/_SHA256 fields are required'
	fi
else
	# Fresh-machine path (no engine yet): derive inline from versions.json.
	[ -f "$root/versions.json" ] || fail 'engine checkout lacks versions.json'
	version=$(json_string neovim)
	case "$version" in ''|*[!0-9.]*) fail 'invalid runtime version' ;; esac
	linux_url=$(json_string neovim_linux_x86_64_url)
	linux_digest=$(json_string neovim_linux_x86_64_sha256)
	darwin_url=$(json_string neovim_darwin_arm64_url)
	darwin_digest=$(json_string neovim_darwin_arm64_sha256)
	# POSIX has no global ${var//}; the version is validated digits/dots
	# first, so the sed program carries no metacharacters.
	subst() {
		printf '%s\n' "$1" | sed "s/{V}/$version/g"
	}
	linux_url=$(subst "$linux_url")
	darwin_url=$(subst "$darwin_url")
fi
validate_record "$version" "$linux_url" "$linux_digest"
validate_record "$version" "$darwin_url" "$darwin_digest"
case "$platform" in
	linux_x86_64) pin_version=$version pin_url=$linux_url pin_digest=$linux_digest ;;
	darwin_arm64) pin_version=$version pin_url=$darwin_url pin_digest=$darwin_digest ;;
esac

parent=$HOME/.local/opt
cache=$WORKSTATION_CACHE/bootstrap
mkdir -p "$parent" "$cache"
lock=$parent/.nvim-bootstrap.lock
waited=0
until mkdir "$lock" 2>/dev/null; do
	waited=$((waited + 1))
	[ "$waited" -le 60 ] || fail "runtime installer locked at $lock (check for an interrupted installer)"
	sleep 1
done
stage=$lock/stage
backup=$lock/previous
partial=$lock/download
cleanup() {
	if [ -d "$backup" ] && [ ! -e "$parent/nvim" ]; then mv "$backup" "$parent/nvim"; fi
	rm -rf "$lock"
}
trap cleanup 0
trap 'exit 1' 1 2 15
archive=$cache/$pin_digest
if [ -e "$archive" ] && { [ -L "$archive" ] || [ "$(hash "$archive")" != "$pin_digest" ]; }; then rm -f "$archive"; fi
if [ ! -f "$archive" ]; then
	curl --proto '=https' --proto-redir '=https' -fSL --retry 3 -o "$partial" "$pin_url"
	[ "$(hash "$partial")" = "$pin_digest" ] || fail 'runtime checksum mismatch'
	mv "$partial" "$archive"
fi
# Reject traversal before extraction. Release archives have one owned root.
tar -tf "$archive" > "$lock/members"
while IFS= read -r name; do
	case "$name" in /*|../*|*/../*|*/..|..) fail 'unsafe runtime archive member' ;; esac
done < "$lock/members"
mkdir "$stage"
tar -xf "$archive" -C "$stage" --strip-components=1
if ! { [ -x "$stage/bin/nvim" ] && [ ! -L "$stage/bin/nvim" ]; }; then fail 'runtime archive lacks executable bin/nvim'; fi
actual=$("$stage/bin/nvim" --version)
case "$actual" in "NVIM v$pin_version"|"NVIM v$pin_version
"*) ;; *) fail 'runtime version mismatch' ;; esac
# Sibling renames; the exit trap restores the previous tree on failed activation.
if [ -e "$parent/nvim" ]; then mv "$parent/nvim" "$backup"; fi
mv "$stage" "$parent/nvim"

# Engine release acquisition: when driven from an engine checkout with a mise
# toolchain (the shim always passes the checkout; the engine's release refresh
# sets WORKSTATION_ENGINE_REPO to the same effect), build the Elixir OTP
# release from source and stage it under the private opt root. This is the
# same acquisition path a fresh machine takes and the only way the public
# launcher ever obtains an engine. Without a checkout the runtime install
# above is the whole contract.
repo=${WORKSTATION_ENGINE_REPO:-}
if [ -n "$repo" ]; then
	if [ ! -f "$repo/elixir/mix.exs" ]; then
		fail "engine checkout at $repo has no elixir/ umbrella"
	fi
	if ! command -v mise >/dev/null 2>&1; then
		fail 'engine checkout present but mise is not on PATH; the release cannot be built'
	fi
	release_stage=$lock/workstation-stage
	mkdir "$release_stage"
	# The daemon-driven release refresh runs this installer as a child of the
	# running engine release, whose launcher exported the installed release's
	# OTP state: an erts-first PATH plus ROOTDIR/BINDIR/RELEASE_ROOT and kin.
	# Under that PATH `mix` resolves erl inside the installed release's ERTS --
	# an erts-only tree with no top-level boot file -- so the build crashes
	# before compiling anything. Strip the installed engine tree from PATH and
	# clear the release launcher variables; mise (or any user toolchain) then
	# resolves normally. A user-shell bootstrap carries none of these.
	build_path=
	old_ifs=$IFS
	IFS=:
	for dir in $PATH; do
		case $dir in
		"$parent"/workstation|"$parent"/workstation/*) ;;
		*) build_path=${build_path:+$build_path:}$dir ;;
		esac
	done
	IFS=$old_ifs
	PATH=$build_path
	export PATH
	unset ROOTDIR BINDIR EMU PROGNAME REL_VSN RELEASE_ROOT
	# Fresh machines have no Hex/Rebar in the fixture-less HOME and mix would
	# prompt; the acquisition must be non-interactive by contract. Locale is
	# pinned because env -i hosts often run a latin1 name encoding.
	if ! (
		cd "$repo/elixir" || exit 1
		LANG=${LANG:-C.UTF-8}
		LC_ALL=${LC_ALL:-C.UTF-8}
		export LANG LC_ALL
		mise exec -- mix local.hex --force || exit 1
		mise exec -- mix local.rebar --force || exit 1
		mise exec -- env MIX_ENV=prod mix deps.get || exit 1
		mise exec -- env MIX_ENV=prod mix release workstation --overwrite
	) >"$release_stage/build.log" 2>&1; then
		[ ! -f "$release_stage/build.log" ] || { echo 'workstation bootstrap: release build failed:' >&2; tail -20 "$release_stage/build.log" >&2; }
		fail 'engine release build failed'
	fi
	# mix release emits the OTP tree under _build/prod/rel/workstation;
	# stage a private copy so activation is a sibling rename, never a
	# partial tree.
	cp -a "$repo/elixir/_build/prod/rel/workstation" "$release_stage/workstation"
	[ -x "$release_stage/workstation/bin/workstation" ] || fail 'built release lacks bin/workstation'
	if [ -e "$parent/workstation" ]; then mv "$parent/workstation" "$lock/workstation-previous"; fi
	mv "$release_stage/workstation" "$parent/workstation"
	# Stamp the activated release with the source HEAD it was built from:
	# the engine's update-refresh staleness check compares this stamp
	# against the checkout to skip no-op rebuilds. A non-git checkout
	# stamps empty, which only costs an honest rebuild.
	git -C "$repo" rev-parse HEAD >"$parent/workstation/.built-from" 2>/dev/null || : >"$parent/workstation/.built-from"
fi

# Runtime and release activation have committed; the caller (the shim's
# bootstrap verb) hands off to the engine release's own bootstrap from here.
