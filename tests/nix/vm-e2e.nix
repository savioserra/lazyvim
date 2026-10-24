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
  engine,
  self,
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
    inherit pkgs engine;
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
  # the user manager's bus: a system-level service has no XDG_RUNTIME_DIR,
  # and every `systemctl --user` / `journalctl --user` below needs it
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
    # the unit's state and journal to the serial console before dying.
    systemctl --user status workstation-daemon.service --no-pager -l 2>&1 | tail -15 >&2 || true
    journalctl --user -u workstation-daemon.service --no-pager 2>&1 | tail -30 >&2 || true
    ls -la $home/.config/systemd/user/ "$home/.config/systemd/user/default.target.wants" 2>&1 | tail -12 >&2 || true
    exit 1
  }

  # 1. the daemon user unit: lingered user manager, active unit, socket bound
  step "daemon user unit active"
  for i in $(seq 1 240); do
    if systemctl --user is-active --quiet workstation-daemon.service 2>/dev/null; then
      break
    fi
    [ $((i % 30)) -eq 0 ] && echo "workstation-e2e:   still waiting for the daemon unit ($i)"
    sleep 1
  done
  systemctl --user is-active --quiet workstation-daemon.service \
    || fail "daemon user unit active" "workstation-daemon.service never became active"
  pass "daemon user unit active"

  step "daemon socket bound"
  sock=""
  for i in $(seq 1 120); do
    sock=$(ls $home/.local/state/workstation/daemon/*.sock 2>/dev/null | head -1)
    [ -n "$sock" ] && break
    [ $((i % 30)) -eq 0 ] && echo "workstation-e2e:   still waiting for the socket ($i)"
    sleep 1
  done
  [ -n "$sock" ] || fail "daemon socket bound" "no socket under $home/.local/state/workstation/daemon/"
  pass "daemon socket bound ($sock)"

  # 2. consumer smoke: the engine answers, the nvim profile link resolves
  step "workstation --version"
  workstation --version >/dev/null 2>&1 \
    || fail "workstation --version" "the engine on PATH does not answer"
  pass "workstation --version"

  step "nvim profile link"
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
  step "agent runtime stack (launcher, interpreter, herdr)"
  [ -x "$home/.local/bin/hermes" ] \
    || fail "agent runtime stack" "$home/.local/bin/hermes is not executable"
  [ -f "$home/.local/opt/hermes/bin/hermes" ] \
    || fail "agent runtime stack" "$home/.local/opt/hermes/bin/hermes missing"
  [ -x "$home/.local/opt/hermes/python/bin/python3" ] \
    || fail "agent runtime stack" "the pinned interpreter did not deploy"
  [ -x "$home/.local/bin/herdr" ] \
    || fail "agent runtime stack" "$home/.local/bin/herdr is not executable"
  pass "agent runtime stack"

  step "agent secrets skill linked"
  [ -r "$home/.hermes/skills/secrets/SKILL.md" ] \
    || fail "agent secrets skill linked" "$home/.hermes/skills/secrets/SKILL.md missing"
  pass "agent secrets skill linked"

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

  step "hsql agent skill provisioned (version-matched, offline)"
  [ -r "$home/.hermes/skills/hsql/SKILL.md" ] \
    || fail "hsql agent skill" "$home/.hermes/skills/hsql/SKILL.md missing"
  pass "hsql agent skill"

  # 3. the apply-driven nix switch: the driver wraps the offline
  #    activation + generation registration, reads the generation and
  #    publishes the receipt over the wire
  step "apply-driven switch (workstation-switch apply)"
  export WORKSTATION_SWITCH_HOME_ACTIVATE="${homeActivate}"
  ${switchDriver}/bin/workstation-switch apply \
    || fail "apply-driven switch" "the driver failed (switch or publish)"
  unset WORKSTATION_SWITCH_HOME_ACTIVATE
  pass "apply-driven switch"

  # 4. the daemon heard it: the `system` domain receipt in the user unit's
  #    journal (the capability logs the exact message it fanned out)
  step "system domain receipt in the daemon journal"
  receipt=$(journalctl --user -u workstation-daemon.service --since "-5 min" --no-pager 2>/dev/null \
    | grep -c "system domain: generation .* applied") || receipt=0
  [ "''${receipt:-0}" -ge 1 ] \
    || fail "system domain receipt" "no 'system domain: generation ... applied' line in the user journal"
  pass "system domain receipt ($receipt lines)"

  echo "workstation-e2e: OK"
''
