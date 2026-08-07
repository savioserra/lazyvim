#!/usr/bin/env bash

repo_root() {
  local source_path="${BASH_SOURCE[0]}"
  local source_dir
  while [[ -L "$source_path" ]]; do
    source_dir="$(cd -P "$(dirname "$source_path")" >/dev/null 2>&1 && pwd)"
    source_path="$(readlink "$source_path")"
    [[ "$source_path" = /* ]] || source_path="$source_dir/$source_path"
  done
  source_dir="$(cd -P "$(dirname "$source_path")" >/dev/null 2>&1 && pwd)"
  cd "$source_dir/../.." >/dev/null 2>&1 && pwd
}

log() {
  printf '\033[1;34m==>\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31merror:\033[0m %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

canonical_path() {
  local source_path="$1"
  local source_dir
  while [[ -L "$source_path" ]]; do
    source_dir="$(cd -P "$(dirname "$source_path")" >/dev/null 2>&1 && pwd)"
    source_path="$(readlink "$source_path")"
    [[ "$source_path" = /* ]] || source_path="$source_dir/$source_path"
  done
  source_dir="$(cd -P "$(dirname "$source_path")" >/dev/null 2>&1 && pwd)"
  printf '%s/%s\n' "$source_dir" "$(basename "$source_path")"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  else
    die "neither sha256sum nor shasum is installed"
  fi
}

checksum_matches() {
  [[ -f "$2" ]] && [[ "$(sha256_file "$2")" == "$1" ]]
}

download_verified() {
  local url="$1"
  local sha256="$2"
  local output="$3"

  mkdir -p "$(dirname "$output")"
  if checksum_matches "$sha256" "$output"; then
    log "Using cached $(basename "$output")"
    return
  fi

  rm -f "$output" "$output.part"
  log "Downloading $(basename "$output")"
  curl --fail --location --retry 5 --retry-all-errors --retry-delay 2 \
    --output "$output.part" "$url"
  mv "$output.part" "$output"
  checksum_matches "$sha256" "$output" || die "checksum mismatch for $output"
}

backup_path() {
  local target="$1"
  local relative="${target#"$HOME"/}"
  local backup_root="$2"
  local destination="$backup_root/$relative"

  mkdir -p "$(dirname "$destination")"
  mv "$target" "$destination"
  log "Backed up $target to $destination"
}

link_managed_path() {
  local source="$1"
  local target="$2"
  local backup_root="$3"

  mkdir -p "$(dirname "$target")"
  if [[ -L "$target" ]] && [[ "$(canonical_path "$target")" == "$(canonical_path "$source")" ]]; then
    log "Already linked: $target"
    return
  fi
  if [[ -e "$target" || -L "$target" ]]; then
    backup_path "$target" "$backup_root"
  fi
  ln -s "$source" "$target"
  log "Linked $target -> $source"
}

mason_receipt_version() {
  local receipt="$1"
  jq -r '.source.id | capture("@(?<version>[^@#]+)(#.*)?$").version' "$receipt"
}
