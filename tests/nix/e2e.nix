# The live proof driver: `workstation-e2e` runs INSIDE the container E2E's
# throwaway nix container (tests/nix/run-container.sh stages the boot home,
# then invokes this driver). Every step is asserted loud on the log the
# host script greps:
#
#   workstation-e2e: <step> ... ok / FAIL
#   workstation-e2e: OK             (the final marker run-container.sh greps)
#
# The apply step drives the workstation-switch driver with a prebuilt
# activation override (WORKSTATION_SWITCH_HOME_ACTIVATE) — the offline
# form of `home-manager switch`: the evaluation happened at build time
# inside the container, so the override does the two things a switch would
# have done, fully offline:
#   1. run the standalone activation (home files, unit files, profile links)
#   2. register the generation the way `home-manager switch` does
#      (nix-env --set on the home-manager profile) — the driver's receipt
#      reads the generation number from that profile link
{
  lib,
  pkgs,
  writeShellScript,
  writeShellScriptBin,
  self,
  # the foundation domain's pinned harlequin version (the flake overlay's —
  # the caller's pkgs predates hsql and carries no real version)
  harlequinVersion,
}:
let
  # the standalone home the apply targets (built from the mounted flake by
  # run-container.sh so both the activation and the profile registration
  # hit realized store paths)
  activation = self.checks.x86_64-linux.e2e-home;

  # the SAME driver derivation workstation-home.nix stages (identical
  # arguments, one store path) — referenced absolutely so the proof does
  # not bet on PATH shape
  switchDriver = import ../../nix/workstation-switch.nix {
    inherit pkgs;
    flake = self;
    homeAttr = "e2e@container";
    # the container lane has no system plane — the fail-closed guard is
    # the designed behavior for a --system call with no target
    systemAttr = null;
  };

  # the offline switch steps: activate + register, exactly what
  # `home-manager switch` would have done for each generation. The boot
  # staging (run-container.sh) activates the full persona directly; the
  # driver's apply targets the minus-go persona below.
  homeActivateMinusGo = writeShellScript "workstation-e2e-home-activate-minus-go" ''
    set -eu
    ${activationMinusGo}/activate
    nix-env --profile "''${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager" \
      --set ${activationMinusGo}
  '';

  # the removal proof's target: the SAME persona home re-applied with go
  # deselected (tests/nix/e2e-selections-minus-go.nix — the full fixture
  # minus languages/go). The driver's second apply activates this: the go
  # toolchain and its profile entry leave, the other selections ride, nvim
  # still boots — the selection removal semantics, proven on a real home.
  activationMinusGo = self.checks.x86_64-linux.e2e-minus-go-home;

  # the init step's userland: the image's bare root carries no sed, awk,
  # hostname or cmp (the minimal nix profile greps and copies but merges
  # nothing), and the shim's identity merge reads and rewrites
  # hosts/identity.nix through exactly those. A real host carries them
  # from the OS or the profile, so the init step alone stages the
  # nixpkgs tools on PATH — every other step keeps proving the shim's
  # read paths run on the bare image (the lane stays sed-free there).
  initTools = pkgs.symlinkJoin {
    name = "workstation-e2e-init-tools";
    paths = [
      pkgs.coreutils
      pkgs.gnused
      pkgs.gawk
      pkgs.diffutils
      # the shim detects the host with `hostname -s`; nixpkgs' coreutils
      # ships hostid/uname but not hostname (it is its own package)
      pkgs.hostname
    ];
  };
in
writeShellScriptBin "workstation-e2e" ''
  set -u

  home=/home/e2e
  export HOME=$home
  export PATH=/run/current-system/sw/bin:$PATH

  step() {
    echo "workstation-e2e: $1 ..."
  }

  pass() {
    echo "workstation-e2e: $1 ... ok"
  }

  fail() {
    echo "workstation-e2e: $1 ... FAIL: $2" >&2
    # The failure is the interesting data on a headless proof host: dump
    # the user unit dir to the log before dying.
    ls -la $home/.config/systemd/user/ "$home/.config/systemd/user/default.target.wants" 2>&1 | tail -12 >&2
    exit 1
  }

  # 1. the retirement: no resident engine process, no socket, no unit.
  #    File-plane only here: the container lane runs without a service
  #    manager, so "systemd knows nothing of the unit" stays a real-host
  #    verify contract — the activation governs the files, and the files
  #    are what this lane asserts.
  step "daemon unit retired"
  if [ -e "$home/.config/systemd/user/workstation-daemon.service" ]; then
    fail "daemon unit retired" "workstation-daemon.service is still staged in the user units"
  fi
  pass "daemon unit retired"

  step "no state socket remains"
  socks=$(find $home/.local/state/workstation -name '*.sock' 2>/dev/null || true)
  [ -z "$socks" ] || fail "no state socket remains" "$socks"
  pass "no state socket remains"

  # 2. consumer smoke: the launcher shim dispatches, the nvim profile link
  #    resolves
  # the home lane's packages land on the profile PATH; resolve through the
  # known profile locations too so the proof never bets on PATH shape
  find_client() {
    local bin
    bin=$(command -v "$1" 2>/dev/null || true)
    if [ -z "$bin" ]; then
      for bin in "$home/.nix-profile/bin/$1" "/etc/profiles/per-user/e2e/bin/$1" /run/current-system/sw/bin/"$1"; do
        [ -x "$bin" ] && { printf '%s\n' "$bin"; return 0; }
      done
      return 1
    fi
    printf '%s\n' "$bin"
  }
  step "launcher shim dispatch (help, usage, unknown verb)"
  shim_bin=$(find_client workstation) \
    || fail "launcher shim dispatch" "workstation is not staged"
  "$shim_bin" help >/dev/null 2>&1 \
    || fail "launcher shim dispatch" "workstation help failed"
  "$shim_bin" frobnicate >/dev/null 2>&1 &&
    fail "launcher shim dispatch" "an unknown verb must fail (exit 2)"
  rc=0
  "$shim_bin" frobnicate >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] \
    || fail "launcher shim dispatch" "unknown verb must exit 2 (got $rc)"
  pass "launcher shim dispatch"

  step "nvim profile link"
  # the container stages the boot home before the driver runs; the bounded
  # settle turns a lost staging race (if one ever returns) from a FAIL
  # into a loud wait
  settle=0
  while [ $settle -lt 90 ]; do
    [ -x "$home/.local/bin/nvim" ] && [ -r "$home/.config/nvim/lua/languages/profile.lua" ] && break
    settle=$((settle + 3))
    sleep 3
  done
  [ -x "$home/.local/bin/nvim" ] \
    || fail "nvim profile link" "$home/.local/bin/nvim is not executable"
  pass "nvim profile link"

  step "deployed language profile"
  prof="$home/.config/nvim/lua/languages/profile.lua"
  [ -r "$prof" ] \
    || fail "deployed language profile" "$prof missing (the composition gap closed natively)"
  grep -q '\["id"\] = "standard"' "$prof" \
    || fail "deployed language profile" "the standard entry is missing from $prof"
  grep -q 'lazyvim.plugins.extras.lang.go' "$prof" \
    || fail "deployed language profile" "the go entry is missing from $prof"
  grep -q 'lazyvim.plugins.extras.lang.elixir' "$prof" \
    || fail "deployed language profile" "the elixir entry is missing from $prof"
  grep -q 'lazyvim.plugins.extras.lang.typescript' "$prof" \
    || fail "deployed language profile" "the typescript entry is missing from $prof (the persona's selection fixture pins it)"
  [ -r "$home/.config/nvim/lua/languages/plugins/elixir.lua" ] \
    || fail "deployed language profile" "the elixir plugin module did not deploy"
  [ -r "$home/.config/nvim/lua/languages/plugins/typescript.lua" ] \
    || fail "deployed language profile" "the typescript plugin module did not deploy"
  pass "deployed language profile"

  step "lazy-lock merge (seeded from the pinned baseline)"
  lock="$home/.config/nvim/lazy-lock.json"
  [ -s "$lock" ] \
    || fail "lazy-lock merge" "$lock was not seeded by the merge activation"
  grep -q 'oasis.nvim' "$lock" \
    || fail "lazy-lock merge" "$lock does not carry the pinned baseline"
  pass "lazy-lock merge"

  # the regression smoke (the vps cutover, 2026-10-27): a composed
  # profile.lua is a lua CHUNK, not a text file — content greps passed
  # while nvim died with E5113 on require. The boot is the proof: nvim
  # headless must exit 0 with every language module composed. First boot
  # restores the lock's plugins (the container is online); the bound keeps
  # a clone storm from hanging the lane.
  step "nvim boots headless with the languages composed"
  nvim_boot() {
    if command -v timeout >/dev/null 2>&1; then
      timeout 600 "$home/.local/bin/nvim" --headless +qa
    else
      "$home/.local/bin/nvim" --headless +qa
    fi
  }
  nvim_boot >/dev/null 2>"$home/.cache/e2e-nvim-boot.err" \
    || fail "nvim boots headless" "nvim --headless +qa exited non-zero (see .cache/e2e-nvim-boot.err in the persona home)"
  pass "nvim boots headless with the languages composed"

  # 2b. the agent domain: the pinned runtime stack, the linked secrets
  #     skill, and the retire-list receipt (the checkout itself is the one
  #     network surface — its ensure activation defers offline with a named
  #     receipt, and the hermes verify lane is the drift gate on real hosts)
  step "agent runtime stack (launcher, interpreter, herdr, pin manifest)"
  [ -x "$home/.local/bin/hermes" ] \
    || fail "agent runtime stack" "$home/.local/bin/hermes is not executable"
  [ -f "$home/.local/opt/hermes/bin/hermes" ] \
    || fail "agent runtime stack" "$home/.local/opt/hermes/bin/hermes missing"
  [ -x "$home/.local/opt/hermes/python/bin/python3" ] \
    || fail "agent runtime stack" "the pinned interpreter did not deploy"
  [ -x "$home/.local/bin/herdr" ] \
    || fail "agent runtime stack" "$home/.local/bin/herdr is not executable"
  grep -Eq '"engine":\{"rev":"[0-9a-f]{40}' "$home/.local/opt/hermes/pin.json" 2>/dev/null \
    || fail "agent runtime stack" "the deployed pin manifest carries no engine rev"
  pass "agent runtime stack"

  step "agent skills served as declared entry symlinks"
  [ -L "$home/.hermes/skills/secrets" ] \
    || fail "agent skills" "$home/.hermes/skills/secrets is not the declared entry symlink"
  case "$(readlink "$home/.hermes/skills/secrets")" in
    /nix/store/*) ;;
    *) fail "agent skills" "$home/.hermes/skills/secrets does not resolve into the store" ;;
  esac
  [ -r "$home/.hermes/skills/secrets/SKILL.md" ] \
    || fail "agent skills" "$home/.hermes/skills/secrets/SKILL.md unreadable through the symlink"
  [ -L "$home/.hermes/skills/hsql" ] \
    || fail "agent skills" "$home/.hermes/skills/hsql is not the declared entry symlink"
  [ -r "$home/.hermes/skills/hsql/SKILL.md" ] \
    || fail "agent skills" "$home/.hermes/skills/hsql/SKILL.md unreadable through the symlink"
  # the explicit profile targeting: the named profile sees the same
  # declared entries
  [ -L "$home/.hermes/profiles/fresh/skills/secrets" ] \
    || fail "agent skills" "the named profile's skills dir carries no secrets entry"
  [ -r "$home/.hermes/profiles/fresh/skills/secrets/SKILL.md" ] \
    || fail "agent skills" "the named profile's secrets entry is unreadable"
  pass "agent skills"

  step "hsql skill version matches the derivation (the hsql precedent)"
  # the skill tree IS this generation's harlequin build — the fully
  # resolved store path carries the derivation version the pin ships (HM
  # may link through its files tree; resolve to the end)
  case "$(readlink -f "$home/.hermes/skills/hsql")" in
    *hsql-agent-skill-${harlequinVersion}) ;;
    *) fail "hsql skill version" \
      "$home/.hermes/skills/hsql does not resolve into the ${harlequinVersion} skill derivation" ;;
  esac
  pass "hsql skill version"

  step "retire-list receipt"
  [ ! -e "$home/.hermes/skills/lazyvim/SKILL.md" ] \
    || fail "retire-list receipt" "the lazyvim tombstone survived activation"
  grep -q " .hermes/skills/lazyvim/SKILL.md absent$" \
    "$home/.local/state/workstation/retire.log" 2>/dev/null \
    || fail "retire-list receipt" "no lazyvim SKILL.md absent receipt from the boot activation"
  grep -q " .config/tmux/themes/tmux2k.conf absent$" \
    "$home/.local/state/workstation/retire.log" 2>/dev/null \
    || fail "retire-list receipt" "no tmux2k.conf absent receipt from the boot activation"
  pass "retire-list receipt"

  step "tmux plane (config, XDG link, pinned plugin checkouts)"
  [ -r "$home/.tmux.conf" ] \
    || fail "tmux plane" "$home/.tmux.conf missing"
  [ -L "$home/.config/tmux/tmux.conf" ] \
    || fail "tmux plane" "the XDG link did not deploy"
  [ -d "$home/.tmux/plugins/tpm" ] \
    || fail "tmux plane" "the tpm checkout did not deploy"
  [ -d "$home/.tmux/plugins/tmux2k" ] \
    || fail "tmux plane" "the tmux2k checkout did not deploy"
  pass "tmux plane"

  step "nunchux plane (pinned checkout, platform marker, rendered config)"
  [ -d "$home/.tmux/plugins/nunchux" ] \
    || fail "nunchux plane" "the pinned checkout did not deploy"
  grep -q 'linux-amd64' "$home/.tmux/plugins/nunchux/bin/.platform" 2>/dev/null \
    || fail "nunchux plane" "the .platform marker did not compose into the checkout"
  [ -r "$home/.config/nunchux/config" ] \
    || fail "nunchux plane" "the rendered config did not deploy"
  grep -q 'fzf_colors = fg+:white:bold' "$home/.config/nunchux/config" \
    || fail "nunchux plane" "the theme slot substitution did not render (text=white missing)"
  grep -q '{{ .theme.slots.' "$home/.config/nunchux/config" \
    && fail "nunchux plane" "unresolved slot references survived the render"
  pass "nunchux plane"

  step "rc lane order (the declared order contract — PATH semantics)"
  # the declared contract (nix/lib/shell-lane.nix): the round-tens `order`
  # is the fragment's slot on the GLOBAL rc scale, composed by the
  # (trailing, order, domain) key with the numbers compared numerically —
  # .profile sources bin(10) < op-env(30) < editor-env(70); .bashrc
  # sources bin(10) < tmux-drain(30) < eza(40) < starship(50) <
  # editor-env(70) < direnv(80) and .zshrc bin(10) < tmux-drain-zsh(30) <
  # eza-zsh(40) < starship-zsh(60) < editor-env(70) < direnv-zsh(90) —
  # the direnv hook trails the prompt, and the operator's extras fragment
  # is the lane's trailing override (its last-word position is the shell
  # lane step's assert). The expectations read the rendered rc files,
  # never the module system's merged list order.
  lane_slot() {
    # lane_slot <rc-file> <fragment-id> — the 1-based source line, empty
    # when absent
    grep -n "shell/$2.sh" "$home/$1" 2>/dev/null | cut -d: -f1 | head -1
  }
  prof_bin=$(lane_slot .profile user-local-bin)
  prof_op=$(lane_slot .profile managed-op-env)
  prof_ed=$(lane_slot .profile managed-editor-env)
  [ -n "$prof_bin" ] && [ -n "$prof_op" ] && [ -n "$prof_ed" ] \
    || fail "rc lane order" ".profile does not source its declared fragments"
  [ "$prof_bin" -lt "$prof_op" ] && [ "$prof_op" -lt "$prof_ed" ] \
    || fail "rc lane order" ".profile must source slots 10/30/70 in the declared order"
  bash_bin=$(lane_slot .bashrc user-local-bin)
  bash_ed=$(lane_slot .bashrc managed-editor-env)
  bash_direnv=$(lane_slot .bashrc managed-direnv)
  bash_drain=$(lane_slot .bashrc tmux-drain)
  bash_eza=$(lane_slot .bashrc managed-eza)
  bash_star=$(lane_slot .bashrc managed-starship)
  [ -n "$bash_bin" ] && [ -n "$bash_ed" ] && [ -n "$bash_direnv" ] \
    && [ -n "$bash_drain" ] && [ -n "$bash_eza" ] && [ -n "$bash_star" ] \
    || fail "rc lane order" ".bashrc does not source its declared fragments"
  # bin leads (PATH semantics — every later fragment may resolve through
  # ~/.local/bin); the aliases and the prompt compose before the editor
  # env; the direnv hook trails the prompt (the hook PREPENDS its export
  # to PROMPT_COMMAND, so hooking after the prompt keeps the environment
  # applied before each prompt rebuild)
  [ "$bash_bin" -lt "$bash_drain" ] && [ "$bash_drain" -lt "$bash_eza" ] \
    && [ "$bash_eza" -lt "$bash_star" ] && [ "$bash_star" -lt "$bash_ed" ] \
    && [ "$bash_ed" -lt "$bash_direnv" ] \
    || fail "rc lane order" ".bashrc must source slots 10/30/40/50/70/80 in the declared order"
  zsh_bin=$(lane_slot .zshrc user-local-bin)
  zsh_ed=$(lane_slot .zshrc managed-editor-env)
  zsh_direnv=$(lane_slot .zshrc managed-direnv-zsh)
  zsh_drain=$(lane_slot .zshrc tmux-drain-zsh)
  zsh_eza=$(lane_slot .zshrc managed-eza-zsh)
  zsh_star=$(lane_slot .zshrc managed-starship-zsh)
  [ -n "$zsh_bin" ] && [ -n "$zsh_ed" ] && [ -n "$zsh_direnv" ] \
    && [ -n "$zsh_drain" ] && [ -n "$zsh_eza" ] && [ -n "$zsh_star" ] \
    || fail "rc lane order" ".zshrc does not source its declared fragments"
  [ "$zsh_bin" -lt "$zsh_drain" ] && [ "$zsh_drain" -lt "$zsh_eza" ] \
    && [ "$zsh_eza" -lt "$zsh_star" ] && [ "$zsh_star" -lt "$zsh_ed" ] \
    && [ "$zsh_ed" -lt "$zsh_direnv" ] \
    || fail "rc lane order" ".zshrc must source slots 10/30/40/60/70/90 in the declared order"
  pass "rc lane order"

  step "migrated tools run (nixpkgs-owned — operator ruling 2026-10-27)"
  for t in fd fzf rg lazygit tree-sitter node pnpm op; do
    t_bin=$(find_client "$t") || fail "migrated tools run" "$t is not on PATH"
    "$t_bin" --version >/dev/null 2>&1 \
      || fail "migrated tools run" "$t --version failed at $t_bin"
  done
  go_bin=$(find_client go) || fail "migrated tools run" "go is not on PATH"
  "$go_bin" version >/dev/null 2>&1 \
    || fail "migrated tools run" "go version failed at $go_bin"
  pass "migrated tools run"

  step "node runtime single-source (.node-version derived from the nixpkgs runtime)"
  nv=$(cat "$home/.node-version" 2>/dev/null || true)
  [ -n "$nv" ] || fail "node runtime single-source" ".node-version missing"
  node_bin=$(find_client node) || fail "node runtime single-source" "node is not on PATH"
  # the version strip is pure shell: the container lane runs in the
  # minimal nix image, where sed does not exist
  runtime=$("$node_bin" --version)
  runtime=''${runtime#v}
  [ "$nv" = "$runtime" ] \
    || fail "node runtime single-source" ".node-version ($nv) does not match the runtime ($runtime)"
  pass "node runtime single-source"

  step "nvm retired (the old runtime manager stays gone)"
  [ ! -e "$home/.local/opt/nvm" ] \
    || fail "nvm retired" ".local/opt/nvm is still deployed"
  [ ! -e "$home/.config/shell/nvm.sh" ] \
    || fail "nvm retired" ".config/shell/nvm.sh is still deployed"
  grep -q " .local/opt/nvm absent$" \
    "$home/.local/state/workstation/retire.log" 2>/dev/null \
    || fail "nvm retired" "no .local/opt/nvm absent receipt from the boot activation"
  pass "nvm retired"

  step "foundation plane (rc lane, starship fragment, fonts)"
  # the rc lane: .profile sources its fragments in the declared order
  # (user-local-bin, managed-op-env)
  grep -q 'shell/user-local-bin.sh' "$home/.profile" \
    || fail "foundation plane" ".profile does not source the PATH fragment"
  grep -q 'shell/managed-op-env.sh' "$home/.profile" \
    || fail "foundation plane" ".profile does not source the op-env fragment"
  [ -r "$home/.config/workstation/shell/managed-starship-zsh.sh" ] \
    || fail "foundation plane" "the per-shell starship fragment did not deploy"
  grep -q 'starship init zsh' "$home/.config/workstation/shell/managed-starship-zsh.sh" \
    || fail "foundation plane" "the zsh fragment carries the wrong init body"
  # the editor env defaults (managed-editor-env, slot 70, every rc
  # target): the fragment body carries the three nvim exports
  for editor_export in 'export EDITOR="nvim"' 'export VISUAL="nvim"' 'export GIT_EDITOR="nvim"'; do
    grep -Fqx "$editor_export" "$home/.config/workstation/shell/managed-editor-env.sh" \
      || fail "foundation plane" "the editor-env fragment misses: $editor_export"
  done
  # the font tree (the nixpkgs nerd-fonts package's font dir)
  [ -d "$home/.local/share/fonts/JetBrainsMonoNerdFont" ] \
    || fail "foundation plane" "the nerd font tree did not deploy"
  pass "foundation plane"

  step "terminal pin manifest (the deployed verify anchor)"
  [ -r "$home/.tmux/plugins.pins.json" ] \
    || fail "terminal pin manifest" "the deployed plugin pin manifest did not deploy"
  grep -q '"tpm":{' "$home/.tmux/plugins.pins.json" \
    || fail "terminal pin manifest" "no tpm pin in the deployed manifest"
  grep -q '"nunchux":{' "$home/.tmux/plugins.pins.json" \
    || fail "terminal pin manifest" "no nunchux pin in the deployed manifest"
  pass "terminal pin manifest"

  step "theme token path deployed (the switch-time push surface)"
  totop="$home/.local/state/workstation/theme.json"
  [ -L "$totop" ] \
    || fail "theme token path" "$totop is not the store token link"
  case "$(readlink "$totop")" in
    /nix/store/*) ;;
    *) fail "theme token path" "$totop does not resolve into the store" ;;
  esac
  grep -q '"dark"' "$totop" \
    || fail "theme token path" "the token file carries no dark palette"
  grep -q '#[0-9a-fA-F]\{6\}' "$totop" \
    || fail "theme token path" "the token file carries no hex roles"
  pass "theme token path deployed"

  # 2c. the adopt rehearsal: a copy-contract tree at a declared entry path
  #     (what real hosts carry from the retired shapes) makes way for the
  #     declared symlink at the next generation
  step "copy-contract tree planted (adopt rehearsal)"
  rm -rf "$home/.hermes/skills/secrets"
  mkdir -p "$home/.hermes/skills/secrets"
  echo "copy-contract drift" >"$home/.hermes/skills/secrets/SKILL.md"
  [ -f "$home/.hermes/skills/secrets/SKILL.md" ] \
    || fail "copy-contract tree planted" "the rehearsal tree did not plant"
  pass "copy-contract tree planted"

  # the retire rehearsal: the vps cutover's failing shape (2026-10-27) —
  # a real directory at a declared tombstone path (the node module's
  # recursive = true is the consent that removes it), the plain-file
  # tombstone beside it, and a directory at a NO-consent tombstone (the
  # skip contract: reported with the fix named, never forced). Planted
  # AFTER the boot activation so the apply-driven switch's retire lane
  # meets them present (a fresh home would receipt them absent and
  # prove nothing).
  step "tombstone shapes planted (retire rehearsal)"
  mkdir -p "$home/.local/opt/nvm/bin" "$home/.config/shell" "$home/.config/tmux/themes"
  echo "stub" >"$home/.local/opt/nvm/bin/node"
  echo "legacy nvm loader" >"$home/.config/shell/nvm.sh"
  mkdir -p "$home/.config/tmux/themes/tmux2k.conf"
  echo "foreign drift" >"$home/.config/tmux/themes/tmux2k.conf/keep"
  [ -f "$home/.local/opt/nvm/bin/node" ] \
    && [ -f "$home/.config/shell/nvm.sh" ] \
    && [ -f "$home/.config/tmux/themes/tmux2k.conf/keep" ] \
    || fail "tombstone shapes planted" "the rehearsal shapes did not plant"
  pass "tombstone shapes planted (retire rehearsal)"

  # 2d. the init merge, live (the identity-merge contract): the capture
  #     MERGES hosts/identity.nix — the shipped TEMPLATE placeholders fill
  #     from detection, the operator's set field (shellExtras — the line a
  #     replace-style init once dropped on a re-run) survives byte for
  #     byte, and a converged re-init is a byte-identical no-op. Like the
  #     selection verbs below: the REAL shim against a writable checkout
  #     copy (whiptail is off PATH here, so the capture takes the
  #     detected values verbatim — the bare-box install shape). The
  #     image's bare root lacks the merge's userland (sed, awk, hostname,
  #     cmp), so this step alone stages the nixpkgs tools a real host
  #     PATH carries.
  step "init merge live (placeholders fill, shellExtras survives, the re-init is byte-identical)"
  initlive=/tmp/ws-init
  mkdir -p "$initlive"
  cp -a /workstation/. "$initlive/"
  printf '%s\n' \
    '{' \
    '  host = "TEMPLATE"; # captured by workstation init (hostname -s)' \
    '  user = "TEMPLATE"; # captured by workstation init' \
    '  home = "/home/TEMPLATE"; # captured by workstation init, the home path' \
    '  shellExtras = "stty -ixon"; # the operator field, kept byte for byte' \
    '}' >"$initlive/hosts/identity.nix"
  init_path=${initTools}/bin:$PATH
  out=$(PATH="$init_path" WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE="$initlive" "$shim_bin" init) \
    || fail "init merge live" "init on the template-plus-shellExtras fixture failed"
  printf '%s' "$out" | grep -q 'identity captured' \
    || fail "init merge live" "the capture must say it captured"
  grep -q TEMPLATE "$initlive/hosts/identity.nix" \
    && fail "init merge live" "init must fill every TEMPLATE placeholder"
  detected_host=$(PATH="$init_path" hostname -s)
  grep -Fqx "  host = \"$detected_host\";" "$initlive/hosts/identity.nix" \
    || fail "init merge live" "init must capture the detected host ($detected_host)"
  grep -Fqx '  user = "e2e";' "$initlive/hosts/identity.nix" \
    || fail "init merge live" "init must capture the detected user (e2e)"
  grep -Fqx '  home = "/home/e2e";' "$initlive/hosts/identity.nix" \
    || fail "init merge live" "init must capture the detected home (/home/e2e)"
  grep -Fqx '  shellExtras = "stty -ixon"; # the operator field, kept byte for byte' \
    "$initlive/hosts/identity.nix" \
    || fail "init merge live" "the operator shellExtras line must survive the merge byte for byte"
  cp "$initlive/hosts/identity.nix" "$initlive/identity.converged"
  out=$(PATH="$init_path" WORKSTATION_NO_APPLY=1 WORKSTATION_FLAKE="$initlive" "$shim_bin" init) \
    || fail "init merge live" "the converged re-init failed"
  printf '%s' "$out" | grep -q 'merged' \
    || fail "init merge live" "the converged re-init must say it merged"
  PATH="$init_path" cmp -s "$initlive/identity.converged" "$initlive/hosts/identity.nix" \
    || fail "init merge live" "a converged re-init must leave the file byte-identical"
  rm -rf "$initlive"
  pass "init merge live (placeholders fill, shellExtras survives, the re-init is byte-identical)"

  # 3. the apply-driven nix switch: the driver wraps the offline
  #    activation + generation registration, then writes the receipt.
  #    THIS apply is also the selection REMOVAL proof: the activation
  #    override targets the minus-go persona (the same home, the next
  #    generation, go deselected), so the asserts after it prove the
  #    removal semantics on a real home.
  step "selection verbs live (a writable checkout copy: selected, add, dedup, refusals)"
  # /workstation is the read-only flake mount; the verbs edit
  # hosts/selections.nix, so they run against a writable copy. The persona
  # home's own selection is a tracked fixture — hermetic against this
  # battery, which proves the shim<->report loop on the checkout copy.
  live=/tmp/ws-live
  mkdir -p "$live"
  cp -a /workstation/. "$live/"
  WORKSTATION_FLAKE=$live WORKSTATION_NO_APPLY=1 "$shim_bin" selected \
    | grep -o '"languages/go":{[^}]*}' | grep -q '"state":"off"' \
    || fail "selection verbs live" "selected must answer the template's off row for languages/go"
  WORKSTATION_FLAKE=$live WORKSTATION_NO_APPLY=1 "$shim_bin" add languages/go >/dev/null \
    || fail "selection verbs live" "add languages/go failed"
  grep -q '"languages/go"' "$live/hosts/selections.nix" \
    || fail "selection verbs live" "add did not write the row to the checkout's selections"
  # the report reads the edited dirty tree back: the row flips the state
  WORKSTATION_FLAKE=$live WORKSTATION_NO_APPLY=1 "$shim_bin" selected \
    | grep -o '"languages/go":{[^}]*}' | grep -q '"state":"on"' \
    || fail "selection verbs live" "selected must answer on after the add (the report must read the dirty tree)"
  WORKSTATION_FLAKE=$live WORKSTATION_NO_APPLY=1 "$shim_bin" add languages/go >/dev/null \
    || fail "selection verbs live" "the repeated add must succeed"
  [ "$(grep -c '"languages/go"' "$live/hosts/selections.nix")" = 1 ] \
    || fail "selection verbs live" "add must dedup by exact path"
  sel_out=$(WORKSTATION_FLAKE=$live WORKSTATION_NO_APPLY=1 "$shim_bin" add foundation 2>&1) \
    && fail "selection verbs live" "add foundation must refuse"
  printf '%s' "$sel_out" | grep -q 'baseline — always on' \
    || fail "selection verbs live" "the baseline refusal must say so"
  WORKSTATION_FLAKE=$live WORKSTATION_NO_APPLY=1 "$shim_bin" remove languages/go >/dev/null \
    || fail "selection verbs live" "remove languages/go failed"
  grep -q '"languages/go"' "$live/hosts/selections.nix" \
    && fail "selection verbs live" "the removed row must leave the file"
  unset shim_bin
  pass "selection verbs live (a writable checkout copy: selected, add, dedup, refusals)"

  step "apply-driven switch (the removal apply: go deselected, next generation)"
  export WORKSTATION_SWITCH_HOME_ACTIVATE="${homeActivateMinusGo}"
  ${switchDriver}/bin/workstation-switch apply \
    || fail "apply-driven switch" "the driver failed (switch or receipt)"
  unset WORKSTATION_SWITCH_HOME_ACTIVATE
  pass "apply-driven switch (the removal apply: go deselected, next generation)"

  step "the removal: go left the profile and the PATH, the rest rides"
  grep -q 'lazyvim.plugins.extras.lang.go' "$prof" \
    && fail "the removal" "the go profile entry survived the go-deselected generation"
  grep -q 'lazyvim.plugins.extras.lang.elixir' "$prof" \
    || fail "the removal" "the elixir entry must ride the go-deselected generation"
  if go_gone=$(find_client go); then
    fail "the removal" "go is still on PATH at $go_gone after the go-deselected generation"
  fi
  find_client node >/dev/null \
    || fail "the removal" "node must ride the go-deselected generation"
  [ -r "$home/.node-version" ] \
    || fail "the removal" ".node-version must ride the go-deselected generation"
  pass "the removal: go left the profile and the PATH, the rest rides"

  step "nvim still boots after the removal"
  nvim_boot >/dev/null 2>"$home/.cache/e2e-nvim-boot-removal.err" \
    || fail "nvim still boots after the removal" "nvim --headless +qa exited non-zero (see .cache/e2e-nvim-boot-removal.err in the persona home)"
  pass "nvim still boots after the removal"

  step "adopt step: the declared symlink replaced the copy-contract tree"
  [ -L "$home/.hermes/skills/secrets" ] \
    || fail "adopt step" "$home/.hermes/skills/secrets did not become the declared symlink"
  [ -r "$home/.hermes/skills/secrets/SKILL.md" ] \
    || fail "adopt step" "the declared skill is unreadable after the adopt"
  grep -q " adopt .hermes/skills/secrets$" \
    "$home/.local/state/workstation/retire.log" 2>/dev/null \
    || fail "adopt step" "no adopt receipt in the retire log"
  pass "adopt step"

  # the retire rehearsal's verdict: the planted shapes met the
  # apply-driven activation — the nvm tree left through the declared
  # consent (removed-recursive: the exact shape plain rm died on in the
  # vps cutover), the file through the plain tombstone (removed), and
  # the no-consent directory was skipped, named, and left standing.
  step "retire rehearsal: the planted tombstones left, verdict-receipted"
  [ ! -e "$home/.local/opt/nvm" ] \
    || fail "retire rehearsal" ".local/opt/nvm survived the activation"
  [ ! -e "$home/.config/shell/nvm.sh" ] \
    || fail "retire rehearsal" ".config/shell/nvm.sh survived the activation"
  [ -d "$home/.config/tmux/themes/tmux2k.conf" ] \
    || fail "retire rehearsal" "the no-consent directory was forced (the skip contract died)"
  grep -q " .local/opt/nvm removed-recursive$" \
    "$home/.local/state/workstation/retire.log" 2>/dev/null \
    || fail "retire rehearsal" "no removed-recursive receipt for .local/opt/nvm"
  grep -q " .config/shell/nvm.sh removed$" \
    "$home/.local/state/workstation/retire.log" 2>/dev/null \
    || fail "retire rehearsal" "no removed receipt for .config/shell/nvm.sh"
  grep -q " .config/tmux/themes/tmux2k.conf skipped-directory$" \
    "$home/.local/state/workstation/retire.log" 2>/dev/null \
    || fail "retire rehearsal" "no skipped-directory receipt for .config/tmux/themes/tmux2k.conf"
  pass "retire rehearsal: the planted tombstones left, verdict-receipted"

  # the shell lane's operator extras (17cd11f5): the persona home declares
  # workstation.foundation.shell.extras, so the apply-driven switch
  # rendered the lane's trailing override (operator-extras, the lane's
  # LAST fragment, .bashrc/.zshrc) — its marker must source after every
  # managed one, and the editor env the lane carries must speak in a
  # fresh login shell. Both assertions mirror the host verify's smoke
  # (modules/foundation/verify/prompt.sh) — mirrored here, never invoked.
  step "shell lane: the operator extras ride last, the editor env speaks in a login shell"
  command -v bash >/dev/null 2>&1 \
    || fail "shell lane" "bash is absent — the login-shell editor-env smoke cannot run"
  for rc in .bashrc .zshrc; do
    grep -Fqx "# workstation: operator extras" "$home/$rc" \
      || fail "shell lane" "$rc carries no operator-extras fragment"
    last_marker=$(grep "^# workstation:" "$home/$rc" | tail -n 1)
    [ "$last_marker" = "# workstation: operator extras" ] \
      || fail "shell lane" "$rc does not source the operator extras last (the trailing override must close the lane)"
  done
  grep -Fqx "stty -ixon" "$home/.config/workstation/shell/operator-extras.sh" \
    || fail "shell lane" "the operator-extras fragment does not carry the persona's declared extras line"
  EDITOR_smoke=$(HOME="$home" bash -lc 'printf %s "$EDITOR"') \
    || fail "shell lane" "a fresh login shell failed to start (the editor-env smoke died)"
  [ "$EDITOR_smoke" = nvim ] \
    || fail "shell lane" "a fresh login shell carries EDITOR='$EDITOR_smoke', expected nvim"
  pass "shell lane: the operator extras ride last, the editor env speaks in a login shell"

  # 4. the switch receipt: the driver's tail appended the generation line
  #    to the state tree's switch.log (the daemon journal is gone with the
  #    daemon)
  step "switch receipt in switch.log"
  # the fresh-host form: the first apply on a bare home receipts
  # "generation 1 applied (no prior generation)"; a re-apply receipts the
  # rollback-available form. Either way the generation line must exist —
  # the switch ran and the receipt closed it.
  grep -Eq "generation [0-9]+ applied \(" \
    "$home/.local/state/workstation/switch.log" 2>/dev/null \
    || fail "switch receipt" "no 'generation N applied' line in switch.log"
  pass "switch receipt in switch.log"

  # 5. the staged client: the shim's read flake (the generation's snapshot
  #    at ~/.local/opt/workstation/flake) and the write driver are staged —
  #    the reads themselves are nix evals and are proven HOST-side (the
  #    same flake the container applied answers status, plan and
  #    capabilities there, where the eval's inputs exist)
  step "staged client (flake snapshot, launcher, switch driver)"
  [ -L "$home/.local/opt/workstation/flake" ] \
    || fail "staged client" "$home/.local/opt/workstation/flake is not the generation's flake snapshot link"
  case "$(readlink -f "$home/.local/opt/workstation/flake")" in
    /nix/store/*) ;;
    *) fail "staged client" "the flake snapshot does not resolve into the store" ;;
  esac
  command -v workstation-switch >/dev/null 2>&1 \
    || [ -x "$home/.nix-profile/bin/workstation-switch" ] \
    || [ -x "/etc/profiles/per-user/e2e/bin/workstation-switch" ] \
    || fail "staged client" "the workstation-switch driver is not staged"
  pass "staged client (flake snapshot, launcher, switch driver)"

  echo "workstation-e2e: OK"
''
