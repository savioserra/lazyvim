#!/bin/sh
set -eu

mode=${1:-verify}
case "$mode" in
  verify|regenerate) ;;
  *) echo "usage: $0 [verify|regenerate]" >&2; exit 2 ;;
esac

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) archive=linux-x86_64; checksum=24e58fb231d50306ee28491f33a170301e99540f7e29ca461e0e80fd1239f8d1 ;;
  Darwin-arm64) archive=osx-aarch_64; checksum=7084c6482e3bb416a33fe2162ba566711773b842e6953bf6cb181647b9ef57c0 ;;
  Darwin-x86_64) archive=osx-x86_64; checksum=7f31625f8bec4929082ae9209e101c1c03692624457cc6332f83736db495ee92 ;;
  *) echo "unsupported code-generation host" >&2; exit 1 ;;
esac

protoc_zip="$tmp/protoc.zip"
curl -fsSL "https://github.com/protocolbuffers/protobuf/releases/download/v33.5/protoc-33.5-${archive}.zip" -o "$protoc_zip"
actual_checksum=$(shasum -a 256 "$protoc_zip" | awk '{print $1}')
if [ "$actual_checksum" != "$checksum" ]; then
  echo "protoc archive checksum mismatch" >&2
  exit 1
fi
unzip -q "$protoc_zip" -d "$tmp/protoc"

mkdir -p "$tmp/npm"
cp "$root/package.json" "$root/package-lock.json" "$tmp/npm/"
npm ci --prefix "$tmp/npm" --ignore-scripts --no-audit --no-fund >/dev/null
(
  cd "$root"
  go build -mod=readonly -o "$tmp/protoc-gen-go" google.golang.org/protobuf/cmd/protoc-gen-go
)
mkdir -p "$tmp/output/api/subagents/v1"
"$tmp/protoc/bin/protoc" -I "$root" \
  --plugin="protoc-gen-go=$tmp/protoc-gen-go" \
  --plugin="protoc-gen-es=$tmp/npm/node_modules/.bin/protoc-gen-es" \
  --go_out="$tmp/output" --go_opt=paths=source_relative \
  --es_out="$tmp/output" --es_opt=target=ts,import_extension=js \
  "$root/api/subagents/v1/subagents.proto"

# protoc-gen-es currently emits an extra trailing blank line. Keep generated
# artifacts compatible with the repository whitespace gate deterministically.
python3 - "$tmp/output/api/subagents/v1/subagents_pb.ts" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
path.write_text(path.read_text().rstrip() + "\n")
PY

for generated in subagents.pb.go subagents_pb.ts; do
  expected="$root/api/subagents/v1/$generated"
  actual="$tmp/output/api/subagents/v1/$generated"
  if [ "$mode" = regenerate ]; then
    cp "$actual" "$expected"
  elif ! cmp -s "$expected" "$actual"; then
    diff -u "$expected" "$actual" || true
    echo "generated artifact is stale: $generated" >&2
    exit 1
  fi
done

for bridge_protocol in \
  "$root/../../home/dot_pi/private_agent/extensions/hosted-pi-bridge/subagents_pb.ts" \
  "$root/../../home/dot_pi/private_agent/extensions/actor-client/subagents_pb.ts"
do
  if [ "$mode" = regenerate ]; then
    mkdir -p "$(dirname "$bridge_protocol")"
    cp "$tmp/output/api/subagents/v1/subagents_pb.ts" "$bridge_protocol"
  elif ! cmp -s "$bridge_protocol" "$tmp/output/api/subagents/v1/subagents_pb.ts"; then
    echo "generated Pi bridge protocol artifact is stale: $bridge_protocol" >&2
    exit 1
  fi
done
