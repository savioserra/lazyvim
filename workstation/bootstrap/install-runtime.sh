#!/bin/sh
# Minimal POSIX runtime installer. bootstrap.pins is generated data, never code.
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
# Fixed record order/count and field validation prohibit unknown/duplicate keys.
{
	IFS= read -r record
	binding=${record#versions-sha256|}
	if ! { [ "$record" = "versions-sha256|$binding" ] && valid_hash "$binding"; }; then fail 'invalid manifest header'; fi
	[ "$(hash "$root/versions.json")" = "$binding" ] || fail 'bootstrap manifest is stale; regenerate from versions.json'
	for expected in linux_x86_64 darwin_arm64; do
		IFS= read -r record
		IFS='|' read -r asset version url digest extra <<EOF
$record
EOF
		if ! { [ "$record" = "$asset|$version|$url|$digest" ] && [ "$asset" = "$expected" ] && [ -z "$extra" ] && valid_hash "$digest"; }; then fail 'invalid manifest record'; fi
		case "$version" in ''|*[!0-9.]*) fail 'invalid runtime version' ;; esac
		case "$url" in https://github.com/neovim/neovim/releases/download/v"$version"/nvim-*.tar.gz) ;; *) fail 'invalid runtime URL' ;; esac
		case "$url" in *[!a-zA-Z0-9./:_-]*) fail 'invalid URL characters' ;; esac
		if [ "$asset" = "$platform" ]; then pin_version=$version; pin_url=$url; pin_digest=$digest; fi
	done
	extra=''
	if IFS= read -r extra || [ -n "$extra" ]; then fail 'unexpected manifest record'; fi
} < "$root/bootstrap/bootstrap.pins"

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
