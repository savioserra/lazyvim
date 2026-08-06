#!/usr/bin/env bash

# Shared installation engine for scripts/install-linux and scripts/install-macos.
# Platform entry points must set the release URLs, hashes, archive layouts,
# platform, host_os, font_installer, and fd_effective_version before calling
# run_unix_install.
# shellcheck disable=SC2154

install_temporaries=()

unix_install_usage() {
  cat <<EOF
Usage: scripts/$(basename "$0") [options]

Install pinned Neovim tooling for $platform and apply this repository's chezmoi
source state. Existing unmanaged files are moved to a timestamped backup; they
are never deleted.

Options:
  --minimal      Install Neovim, chezmoi, and managed configuration only
  --no-font      Do not install JetBrainsMono Nerd Font
  --no-restore   Do not restore plugins, Mason tools, or parsers
  -h, --help     Show this help
EOF
}

validate_platform_configuration() {
  local variable
  for variable in \
    platform host_os font_installer \
    neovim_url neovim_sha256 neovim_extracted \
    chezmoi_url chezmoi_sha256 \
    ripgrep_url ripgrep_sha256 ripgrep_extracted \
    fd_effective_version fd_url fd_sha256 fd_extracted \
    fzf_url fzf_sha256 \
    lazygit_url lazygit_sha256 \
    tree_sitter_url tree_sitter_sha256; do
    [[ -n "${!variable:-}" ]] || die "platform installer did not set: $variable"
  done
}

cleanup_install_temporaries() {
  local temporary
  # macOS ships Bash 3.2, where an empty array expansion fails under nounset.
  for temporary in "${install_temporaries[@]:-}"; do
    [[ -z "$temporary" ]] || rm -rf "$temporary"
  done
}

register_install_temporary() {
  install_temporaries+=("$1")
}

clear_macos_quarantine() {
  if [[ "$host_os" == "Darwin" ]] && command -v xattr >/dev/null 2>&1; then
    xattr -cr "$1" 2>/dev/null || true
  fi
}

legacy_binary_matches_platform() {
  local description
  description="$(file -b "$1")"
  case "$platform" in
    linux-x86_64) [[ "$description" == *ELF* && "$description" == *x86-64* ]] ;;
    darwin-arm64) [[ "$description" == *Mach-O* && "$description" == *arm64* ]] ;;
    darwin-x86_64) [[ "$description" == *Mach-O* && "$description" == *x86_64* ]] ;;
    *) return 1 ;;
  esac
}

release_is_installed() {
  local target="$1"
  local expected_binary="$2"
  local marker_value="$3"
  local display_name="$4"
  local marker="$target/.dotfiles-release"

  [[ -x "$target/$expected_binary" ]] || return 1
  if [[ -f "$marker" ]]; then
    [[ "$(cat "$marker")" == "$marker_value" ]] || return 1
  else
    # Adopt pre-marker installations only after checking their executable format.
    legacy_binary_matches_platform "$target/$expected_binary" || return 1
    printf '%s\n' "$marker_value" >"$marker"
    log "Recorded release identity for existing $display_name"
  fi
  return 0
}

write_release_marker() {
  printf '%s\n' "$2" >"$1/.dotfiles-release"
}

install_tar_directory() {
  local name="$1"
  local version="$2"
  local url="$3"
  local sha256="$4"
  local archive_name="$5"
  local extracted_name="$6"
  local expected_binary="$7"
  local target="$opt_home/$name-$version"
  local marker_value="$platform:$sha256"

  if release_is_installed "$target" "$expected_binary" "$marker_value" "$name $version"; then
    log "Already installed: $name $version"
    return
  fi
  if [[ -e "$target" ]]; then
    backup_path "$target" "$backup_root"
  fi

  local archive="$cache_home/$archive_name"
  local temporary
  temporary="$(mktemp -d)"
  register_install_temporary "$temporary"
  download_verified "$url" "$sha256" "$archive"
  tar -xf "$archive" -C "$temporary"
  [[ -d "$temporary/$extracted_name" ]] || die "unexpected archive layout for $name"
  mv "$temporary/$extracted_name" "$target"
  clear_macos_quarantine "$target"
  [[ -x "$target/$expected_binary" ]] || die "$name did not install correctly"
  write_release_marker "$target" "$marker_value"
  log "Installed $name $version"
}

install_flat_tar() {
  local name="$1"
  local version="$2"
  local url="$3"
  local sha256="$4"
  local archive_name="$5"
  local expected_binary="$6"
  local target="$opt_home/$name-$version"
  local marker_value="$platform:$sha256"

  if release_is_installed "$target" "$expected_binary" "$marker_value" "$name $version"; then
    log "Already installed: $name $version"
    return
  fi
  if [[ -e "$target" ]]; then
    backup_path "$target" "$backup_root"
  fi

  local archive="$cache_home/$archive_name"
  download_verified "$url" "$sha256" "$archive"
  mkdir -p "$target"
  tar -xf "$archive" -C "$target"
  clear_macos_quarantine "$target"
  [[ -x "$target/$expected_binary" ]] || die "$name did not install correctly"
  write_release_marker "$target" "$marker_value"
  log "Installed $name $version"
}

install_neovim() {
  install_tar_directory \
    nvim "$NEOVIM_VERSION" "$neovim_url" "$neovim_sha256" \
    "nvim-${NEOVIM_VERSION}-${platform}.tar.gz" "$neovim_extracted" "bin/nvim"
}

install_chezmoi() {
  install_flat_tar \
    chezmoi "$CHEZMOI_VERSION" "$chezmoi_url" "$chezmoi_sha256" \
    "chezmoi-${CHEZMOI_VERSION}-${platform}.tar.gz" "chezmoi"
}

install_companion_tools() {
  install_tar_directory \
    ripgrep "$RIPGREP_VERSION" "$ripgrep_url" "$ripgrep_sha256" \
    "ripgrep-${RIPGREP_VERSION}-${platform}.tar.gz" "$ripgrep_extracted" "rg"

  install_tar_directory \
    fd "$fd_effective_version" "$fd_url" "$fd_sha256" \
    "fd-${fd_effective_version}-${platform}.tar.gz" "$fd_extracted" "fd"

  local fzf_target="$opt_home/fzf-$FZF_VERSION"
  local fzf_marker="$platform:$fzf_sha256"
  if release_is_installed "$fzf_target" "bin/fzf" "$fzf_marker" "fzf $FZF_VERSION"; then
    log "Already installed: fzf $FZF_VERSION"
  else
    [[ ! -e "$fzf_target" ]] || backup_path "$fzf_target" "$backup_root"
    local fzf_archive="$cache_home/fzf-${FZF_VERSION}-${platform}.tar.gz"
    download_verified "$fzf_url" "$fzf_sha256" "$fzf_archive"
    mkdir -p "$fzf_target/bin"
    tar -xf "$fzf_archive" -C "$fzf_target/bin" fzf
    clear_macos_quarantine "$fzf_target"
    [[ -x "$fzf_target/bin/fzf" ]] || die "fzf did not install correctly"
    write_release_marker "$fzf_target" "$fzf_marker"
    log "Installed fzf $FZF_VERSION"
  fi

  install_flat_tar \
    lazygit "$LAZYGIT_VERSION" "$lazygit_url" "$lazygit_sha256" \
    "lazygit-${LAZYGIT_VERSION}-${platform}.tar.gz" "lazygit"

  local tree_sitter_target="$opt_home/tree-sitter-$TREE_SITTER_VERSION"
  local tree_sitter_marker="$platform:$tree_sitter_sha256"
  if release_is_installed \
    "$tree_sitter_target" "bin/tree-sitter" "$tree_sitter_marker" "tree-sitter $TREE_SITTER_VERSION"; then
    log "Already installed: tree-sitter $TREE_SITTER_VERSION"
  else
    [[ ! -e "$tree_sitter_target" ]] || backup_path "$tree_sitter_target" "$backup_root"
    local tree_sitter_archive="$cache_home/tree-sitter-${TREE_SITTER_VERSION}-${platform}.zip"
    download_verified "$tree_sitter_url" "$tree_sitter_sha256" "$tree_sitter_archive"
    mkdir -p "$tree_sitter_target/bin"
    unzip -q "$tree_sitter_archive" -d "$tree_sitter_target/bin"
    chmod +x "$tree_sitter_target/bin/tree-sitter"
    clear_macos_quarantine "$tree_sitter_target"
    write_release_marker "$tree_sitter_target" "$tree_sitter_marker"
    log "Installed tree-sitter $TREE_SITTER_VERSION"
  fi
}

font_is_current() {
  [[ -f "$1" ]] || return 1
  command -v strings >/dev/null 2>&1 || return 1
  strings "$1" 2>/dev/null | grep "Nerd Fonts $NERD_FONT_VERSION" >/dev/null
}

install_linux_font() {
  local target="$data_home/fonts/JetBrainsMonoNerdFont"
  if font_is_current "$target/JetBrainsMonoNerdFont-Regular.ttf"; then
    log "Already installed: JetBrainsMono Nerd Font $NERD_FONT_VERSION"
    return
  fi
  if [[ -e "$target" ]]; then
    backup_path "$target" "$backup_root"
  fi

  local archive="$cache_home/JetBrainsMono-${NERD_FONT_VERSION}.tar.xz"
  download_verified "$NERD_FONT_UNIX_URL" "$NERD_FONT_UNIX_SHA256" "$archive"
  mkdir -p "$target"
  tar -xf "$archive" -C "$target"
  command -v fc-cache >/dev/null 2>&1 && fc-cache -f "$target" >/dev/null
  log "Installed JetBrainsMono Nerd Font $NERD_FONT_VERSION"
}

install_macos_font() {
  local font_home="$HOME/Library/Fonts"
  local regular="$font_home/JetBrainsMonoNerdFont-Regular.ttf"
  if font_is_current "$regular"; then
    log "Already installed: JetBrainsMono Nerd Font $NERD_FONT_VERSION"
    return
  fi

  local archive="$cache_home/JetBrainsMono-${NERD_FONT_VERSION}.tar.xz"
  local temporary
  temporary="$(mktemp -d)"
  register_install_temporary "$temporary"
  download_verified "$NERD_FONT_UNIX_URL" "$NERD_FONT_UNIX_SHA256" "$archive"
  tar -xf "$archive" -C "$temporary"
  mkdir -p "$font_home"

  local destination
  local backup
  while IFS= read -r font; do
    destination="$font_home/$(basename "$font")"
    if [[ -e "$destination" ]]; then
      backup="$backup_root/Library/Fonts/$(basename "$font")"
      mkdir -p "$(dirname "$backup")"
      mv "$destination" "$backup"
    fi
    cp "$font" "$destination"
  done < <(find "$temporary" -type f -name '*.ttf' -print)

  font_is_current "$regular" || die "JetBrainsMono Nerd Font did not install correctly"
  log "Installed JetBrainsMono Nerd Font $NERD_FONT_VERSION"
}

apply_chezmoi_configuration() {
  local chezmoi="$opt_home/chezmoi-$CHEZMOI_VERSION/chezmoi"
  local migration_marker="$state_home/chezmoi-source-state-v1"
  local managed_nvim="$HOME/.config/nvim"
  local target

  if [[ ! -f "$migration_marker" ]]; then
    for target in "$managed_nvim" "$HOME/.tmux.conf"; do
      if [[ -e "$target" || -L "$target" ]]; then
        backup_path "$target" "$backup_root"
      fi
    done
  fi

  log "Applying managed configuration with chezmoi"
  "$chezmoi" --source "$REPO_ROOT" --destination "$HOME" apply
  touch "$migration_marker"

  if [[ "$config_home/nvim" != "$managed_nvim" ]]; then
    link_managed_path "$managed_nvim" "$config_home/nvim" "$backup_root"
  fi

  if command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; then
    tmux source-file "$HOME/.tmux.conf"
    log "Reloaded the active tmux server"
  fi
}

run_unix_install() {
  validate_platform_configuration

  local install_companions=true
  local install_font=true
  local run_restore=true
  while (($#)); do
    case "$1" in
      --minimal)
        install_companions=false
        install_font=false
        ;;
      --no-font) install_font=false ;;
      --no-restore) run_restore=false ;;
      -h | --help)
        unix_install_usage
        return
        ;;
      *)
        unix_install_usage >&2
        die "unknown option: $1"
        ;;
    esac
    shift
  done

  for command in curl file tar unzip readlink; do
    require_command "$command"
  done
  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    die "a SHA-256 utility is required (sha256sum or shasum)"
  fi
  if $run_restore; then
    require_command git
    require_command jq
  fi

  opt_home="${DOTFILES_OPT_HOME:-$HOME/.local/opt}"
  bin_home="${DOTFILES_BIN_HOME:-$HOME/.local/bin}"
  config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
  data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
  case "$data_home" in
    "$HOME"/snap/code/*/.local/share) data_home="$HOME/.local/share" ;;
  esac
  cache_home="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/downloads"
  state_home="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles"
  backup_root="$state_home/backups/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir -p "$opt_home" "$bin_home" "$config_home" "$cache_home" "$state_home"

  trap cleanup_install_temporaries EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  install_neovim
  install_chezmoi
  $install_companions && install_companion_tools
  if $install_font; then
    case "$font_installer" in
      linux) install_linux_font ;;
      macos) install_macos_font ;;
      *) die "unsupported font installer: $font_installer" ;;
    esac
  fi

  apply_chezmoi_configuration
  link_managed_path "$REPO_ROOT/packages/bin/nvim" "$bin_home/nvim" "$backup_root"
  link_managed_path "$opt_home/chezmoi-$CHEZMOI_VERSION/chezmoi" "$bin_home/chezmoi" "$backup_root"

  if $install_companions; then
    link_managed_path "$opt_home/ripgrep-$RIPGREP_VERSION/rg" "$bin_home/rg" "$backup_root"
    link_managed_path "$opt_home/fd-$fd_effective_version/fd" "$bin_home/fd" "$backup_root"
    link_managed_path "$opt_home/fzf-$FZF_VERSION/bin/fzf" "$bin_home/fzf" "$backup_root"
    link_managed_path "$opt_home/lazygit-$LAZYGIT_VERSION/lazygit" "$bin_home/lazygit" "$backup_root"
    link_managed_path "$opt_home/tree-sitter-$TREE_SITTER_VERSION/bin/tree-sitter" "$bin_home/tree-sitter" "$backup_root"
  fi

  if $run_restore; then
    "$REPO_ROOT/scripts/restore"
  fi

  cleanup_install_temporaries
  trap - EXIT HUP INT TERM
  log "Installation complete for $platform"
  printf 'Ensure %s is in PATH, then run: nvim\n' "$bin_home"
}
