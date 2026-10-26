# The live proof driver: `workstation-e2e` runs INSIDE the VM as the vm
# user (the workstation-e2e oneshot unit in vm-host.nix). Every step is
# asserted loud on the serial console:
#
#   workstation-e2e: <step> ... ok / FAIL
#   workstation-e2e: OK                       (the final marker run-vm greps)
#
# The apply step drives the workstation-switch driver with a prebuilt
# activation override (WORKSTATION_SWITCH_HOME_ACTIVATE) — the offline
# form of `home-manager switch`: the evaluation happened at build time on
# the host, so the override does the two things a switch would have done,
# fully offline:
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
  # the standalone home the apply targets (staged into the VM closure by
  # vm-host.nix so both the activation and the profile registration hit
  # realized store paths)
  activation = self.homeConfigurations."vm@vm".activationPackage;

  # the SAME driver derivation workstation-home.nix stages (identical
  # arguments, one store path) — referenced absolutely so the proof does
  # not bet on PATH shape
  switchDriver = import ../../nix/workstation-switch.nix {
    inherit pkgs;
    flake = self;
    homeAttr = "vm@vm";
    systemAttr = "vm-test";
  };

  # the offline switch step: activate + register, exactly what
  # `home-manager switch` would have done for this generation
  homeActivate = writeShellScript "workstation-e2e-home-activate" ''
    set -eu
    ${activation}/activate
    nix-env --profile "''${XDG_STATE_HOME:-$HOME/.local/state}/nix/profiles/home-manager" \
      --set ${activation}
  '';
in
writeShellScriptBin "workstation-e2e" ''
  set -u

  home=/home/vm
  export HOME=$home
  export PATH=/run/current-system/sw/bin:$PATH
  # the user manager's bus: the retirement probe below asks systemctl --user
  export XDG_RUNTIME_DIR=/run/user/$(id -u)

  step() {
    echo "workstation-e2e: $1 ..."
  }

  pass() {
    echo "workstation-e2e: $1 ... ok"
  }

  fail() {
    echo "workstation-e2e: $1 ... FAIL: $2" >&2
    # The failure is the interesting data on a headless proof host: dump
    # the user unit dir to the serial console before dying.
    ls -la $home/.config/systemd/user/ "$home/.config/systemd/user/default.target.wants" 2>&1 | tail -12 >&2
    exit 1
  }

  # 1. the retirement: no resident engine process, no socket, no unit
  step "daemon unit retired"
  if [ -e "$home/.config/systemd/user/workstation-daemon.service" ]; then
    fail "daemon unit retired" "workstation-daemon.service is still staged in the user units"
  fi
  systemctl --user cat workstation-daemon.service >/dev/null 2>&1 \
    && fail "daemon unit retired" "systemd still knows workstation-daemon.service" \
    || true
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
      for bin in "$home/.nix-profile/bin/$1" "/etc/profiles/per-user/vm/bin/$1" /run/current-system/sw/bin/"$1"; do
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
  # belt and suspenders for the boot home: the unit ordering guarantees the
  # home-manager activation completed; the bounded settle turns a lost
  # ordering race (if one ever returns) from a FAIL into a loud wait
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
  [ -r "$home/.config/nvim/lua/languages/plugins/elixir.lua" ] \
    || fail "deployed language profile" "the elixir plugin module did not deploy"
  pass "deployed language profile"

  step "lazy-lock merge (seeded from the pinned baseline)"
  lock="$home/.config/nvim/lazy-lock.json"
  [ -s "$lock" ] \
    || fail "lazy-lock merge" "$lock was not seeded by the merge activation"
  grep -q 'oasis.nvim' "$lock" \
    || fail "lazy-lock merge" "$lock does not carry the pinned baseline"
  pass "lazy-lock merge"

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
  grep -q " .hermes/skills/lazyvim/SKILL.md$" \
    "$home/.local/state/workstation/retire.log" 2>/dev/null \
    || fail "retire-list receipt" "no lazyvim SKILL.md receipt in the retire log"
  grep -q " .config/tmux/themes/tmux2k.conf$" \
    "$home/.local/state/workstation/retire.log" 2>/dev/null \
    || fail "retire-list receipt" "no tmux2k.conf receipt in the retire log"
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

  step "foundation plane (rc lane, foundation pins, fonts, op)"
  # the rc lane: .profile sources its fragments in the declared order
  # (user-local-bin, managed-nvm, managed-op-env)
  grep -q 'shell/user-local-bin.sh' "$home/.profile" \
    || fail "foundation plane" ".profile does not source the PATH fragment"
  grep -q 'shell/managed-nvm.sh' "$home/.profile" \
    || fail "foundation plane" ".profile does not source the nvm fragment"
  grep -q 'shell/managed-op-env.sh' "$home/.profile" \
    || fail "foundation plane" ".profile does not source the op-env fragment"
  [ -r "$home/.config/workstation/shell/managed-starship-zsh.sh" ] \
    || fail "foundation plane" "the per-shell starship fragment did not deploy"
  grep -q 'starship init zsh' "$home/.config/workstation/shell/managed-starship-zsh.sh" \
    || fail "foundation plane" "the zsh fragment carries the wrong init body"
  # the checksummed pins link straight from their store trees
  [ -x "$home/.local/bin/rg" ] \
    || fail "foundation plane" "rg is not linked"
  # the op CLI + the font tree
  [ -x "$home/.local/bin/op" ] \
    || fail "foundation plane" "op is not linked"
  [ -d "$home/.local/share/fonts/JetBrainsMonoNerdFont" ] \
    || fail "foundation plane" "the nerd font tree did not deploy"
  pass "foundation plane"

  step "theme token path deployed (the switch-time push surface)"
  toktop="$home/.local/state/workstation/theme.json"
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

  # 3. the apply-driven nix switch: the driver wraps the offline
  #    activation + generation registration, then writes the receipt
  step "apply-driven switch (workstation-switch apply)"
  export WORKSTATION_SWITCH_HOME_ACTIVATE="${homeActivate}"
  ${switchDriver}/bin/workstation-switch apply \
    || fail "apply-driven switch" "the driver failed (switch or receipt)"
  unset WORKSTATION_SWITCH_HOME_ACTIVATE
  pass "apply-driven switch"

  step "adopt step: the declared symlink replaced the copy-contract tree"
  [ -L "$home/.hermes/skills/secrets" ] \
    || fail "adopt step" "$home/.hermes/skills/secrets did not become the declared symlink"
  [ -r "$home/.hermes/skills/secrets/SKILL.md" ] \
    || fail "adopt step" "the declared skill is unreadable after the adopt"
  grep -q " adopt .hermes/skills/secrets$" \
    "$home/.local/state/workstation/retire.log" 2>/dev/null \
    || fail "adopt step" "no adopt receipt in the retire log"
  pass "adopt step"

  # 4. the switch receipt: the driver's tail appended the generation line
  #    to the state tree's switch.log (the daemon journal is gone with the
  #    daemon)
  step "switch receipt in switch.log"
  grep -q "generation [0-9]* applied (rollback available at" \
    "$home/.local/state/workstation/switch.log" 2>/dev/null \
    || fail "switch receipt" "no 'generation N applied' line in switch.log"
  pass "switch receipt in switch.log"

  # 5. the staged client: the shim's read flake (the generation's snapshot
  #    at ~/.local/opt/workstation/flake) and the write driver are staged —
  #    the reads themselves are nix evals and are proven HOST-side
  #    (tests/direct-nix.sh: the same flake the VM applied answers status,
  #    plan and capabilities there, where the eval's inputs exist)
  step "staged client (flake snapshot, launcher, switch driver)"
  [ -L "$home/.local/opt/workstation/flake" ] \
    || fail "staged client" "$home/.local/opt/workstation/flake is not the generation's flake snapshot link"
  case "$(readlink -f "$home/.local/opt/workstation/flake")" in
    /nix/store/*) ;;
    *) fail "staged client" "the flake snapshot does not resolve into the store" ;;
  esac
  command -v workstation-switch >/dev/null 2>&1 \
    || [ -x "$home/.nix-profile/bin/workstation-switch" ] \
    || [ -x "/etc/profiles/per-user/vm/bin/workstation-switch" ] \
    || fail "staged client" "the workstation-switch driver is not staged"
  pass "staged client (flake snapshot, launcher, switch driver)"

  echo "workstation-e2e: OK"
''
