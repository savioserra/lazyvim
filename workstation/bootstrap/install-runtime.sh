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
# Keep bootstrap serialized through the Lua backend handoff. Runtime activation
# has committed; a backend failure reports failure without undoing valid runtime.
"$parent/nvim/bin/nvim" -l "$root/apps/cli/run.lua" bootstrap
