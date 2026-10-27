# The base shell environment: the rc lane + fd, fzf, rg, lazygit,
# tree-sitter (nixpkgs, floored at the retired download pins' versions —
# operator ruling 2026-10-27), eza + starship (nixpkgs — the prompt
# capability dissolved here), mise (nixpkgs — the binary only, no managed
# footprint), direnv + nix-direnv (nixpkgs — the per-repo environment
# layer; the hooks ride the fragment lane below), harlequin + hsql (one
# upstream distribution;
# the pinned nixpkgs predates hsql, so the foundation domain owns its pin
# surface through the flake's pin-override overlay), and the tailscale
# transport (the system legs declare services.tailscale through the system
# module; workstation.foundation.tailscale.* is the options surface).
#
# Shell fragments: the bodies are payload files beside this module; each
# declares its `order` slot — the rc lane's composition order is PATH
# semantics and is never derived (nix/lib/shell-lane.nix sorts the lane;
# a shared or ambiguous slot fails the eval). The hsql agent skill is
# generated from the INSTALLED derivation at build time (hsql --skill) —
# version-matched by construction, offline — and serves as a declared entry
# symlink (programs.hermes.skills.hsql); no activation lane writes into
# hot home.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  # the foundation tools ride nixpkgs (operator ruling 2026-10-27: the
  # pins machinery is redundant — nixpkgs maintains these five, security
  # backports included). Each is floored at the retired download pin's
  # version (the harlequin precedent): the pinned 25.05 set predates the
  # floors, so the flake's pin-override overlay must be applied — an
  # unapplied overlay (or a lagging lock) dies here instead of quietly
  # downgrading the fleet.
  floored =
    name: floor: pkg:
    assert
      lib.versionAtLeast (pkg.version or "0") floor
      || throw "workstation-foundation: pkgs.${name} ${pkg.version or "?"} predates the floor ${floor} — the flake's overlays.default (the foundation domain's pin surface) must be applied (nixpkgs.overlays) and its lock must carry the version";
    pkg;
  tools = {
    fd = floored "fd" "10.4.2" pkgs.fd;
    fzf = floored "fzf" "0.74.2" pkgs.fzf;
    ripgrep = floored "ripgrep" "15.2.0" pkgs.ripgrep;
    lazygit = floored "lazygit" "0.63.1" pkgs.lazygit;
    tree-sitter = floored "tree-sitter" "0.26.11" pkgs.tree-sitter;
  };

  # the fragment payload (id, order slot, marker, payload path the rc lane
  # declares; bodies live beside the module at their final address). The
  # starship init is per-shell — the two bodies get their own ids and
  # slots. The slots (round tens): the user-local bin fragment LEADS (PATH
  # semantics — every later fragment may resolve through ~/.local/bin),
  # the login glue follows, aliases then the prompt, and the direnv pair
  # hooks last (the hook PREPENDS its export to PROMPT_COMMAND, so hooking
  # after the prompt keeps the environment applied before each prompt
  # rebuild).
  frag = id: order: marker: {
    inherit id order marker;
    payload = ./fragments + "/${id}.sh";
  };

  # the declared list: the rc contract's slots, per target (the retired
  # mise and nvm fragments' slots stay retired — 30 is the secrets domain's
  # op-env slot)
  fragments = [
    (frag "user-local-bin" 10 "# workstation: managed user-local bin")
    (frag "managed-profile" 20 "# workstation: load managed profile")
    (frag "managed-eza" 40 "# workstation: managed eza ls")
    (frag "managed-starship" 50 "# workstation: managed starship prompt")
    (frag "managed-starship-zsh" 60 "# workstation: managed starship prompt")
    (frag "managed-direnv" 80 "# workstation: managed direnv hook")
    (frag "managed-direnv-zsh" 90 "# workstation: managed direnv hook")
  ];

  fragmentTargets = {
    user-local-bin = [
      ".profile"
      ".bashrc"
      ".zshrc"
    ];
    managed-profile = [ ".bash_profile" ];
    managed-eza = [
      ".bashrc"
      ".zshrc"
    ];
    managed-starship = [ ".bashrc" ];
    managed-starship-zsh = [ ".zshrc" ];
    managed-direnv = [ ".bashrc" ];
    managed-direnv-zsh = [ ".zshrc" ];
  };

  # the option's entries: one per (id, target) pair — the fragment's slot
  # rides along (the lane's order contract reads it)
  fragmentEntries = lib.concatMap (
    f:
    map (target: {
      inherit target;
      id = f.id;
      order = f.order;
      marker = f.marker;
      payload = f.payload;
    }) fragmentTargets.${f.id}
  ) fragments;

  # the starship config payload, co-located beside this module (the
  # dissolved prompt capability's bytes live with their owner)
  starshipToml = ./starship.toml;

  # the hsql agent skill: generated from the installed derivation by the
  # tool's own --skill generator (the hsql precedent — a tool that ships
  # one serves its skill version-matched, offline, from the store). The
  # generator decides file-vs-dir by the target's existence, so the build
  # stages into a pre-created dir and copies out — one shape, always.
  hsqlSkill =
    pkgs.runCommand "hsql-agent-skill-${pkgs.harlequin.version}"
      {
        nativeBuildInputs = [ pkgs.harlequin ];
        passthru.version = pkgs.harlequin.version;
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" "$TMPDIR/skill"
        hsql --skill -o "$TMPDIR/skill"
        mkdir -p "$out"
        cp -a "$TMPDIR/skill/." "$out/"
      '';
in
{
  options.workstation.foundation = {
    tailscale.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        The fleet transport (ssh, the dashboard's --host binding, all host
        convergence ride it). The system legs declare services.tailscale
        through the system module; the host's MagicDNS name comes from
        workstation.host.tailscale.fqdn.
      '';
    };
    tailscale.acceptDns = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Accept the tailnet's DNS settings on the transport. Declared per
        host; the wiring lands with the first transport module that carries
        the option (the NixOS module integrates the tailnet DNS on enable).
      '';
    };
  };

  config = {
    # the shell lane: this domain's fragments in the declared order
    workstation.shell.fragments = fragmentEntries;

    home.file = {
      ".config/starship.toml".source = starshipToml;
    };

    home.packages = [
      # the foundation tools: nixpkgs-owned, floored at the retired
      # download pins' versions (the floors above make an unapplied
      # overlay or a lagging lock die at eval — a quiet downgrade of the
      # fleet's tool set is never a silent act)
      tools.fd
      tools.fzf
      tools.ripgrep
      tools.lazygit
      tools.tree-sitter
      # the dissolved prompt capability: eza is the managed ls (icons),
      # starship the cross-shell prompt — both nixpkgs-native
      pkgs.eza
      pkgs.starship
      # mise (mise-en-place): the nixpkgs-native binary only — per-project
      # runtime versioning (`mise use`, `.mise.toml`, `mise x`) on every
      # managed host, the pin riding the nixpkgs lock. The engine owns
      # nothing around it: no managed MISE_DATA_DIR, no `.local/bin/mise`
      # launcher, no activation fragment — the retired managed-mise lane's
      # split-brain (t_1ae61704) stays structurally dead, and shell
      # activation (`mise activate`) is operator opt-in (its own card, if
      # ever — it shadows PATH tools).
      pkgs.mise
      # whiptail (the newt package): the launcher shim's install-time UI —
      # `workstation init` captures the machine's identity through whiptail
      # dialogs prefilled with the detected values. A prerequisite of the
      # bin surface, shipped by the substrate so every managed host has it.
      pkgs.newt
      # harlequin + hsql: one upstream distribution (the terminal SQL IDE
      # and its headless agent CLI share adapters, config and engine). The
      # pinned nixpkgs (25.05) predates hsql — the version rides the
      # flake's pin-override overlay; the floor makes an unapplied overlay
      # die loudly here instead of quietly shipping a hsql-less IDE.
      (
        assert
          lib.versionAtLeast (pkgs.harlequin.version or "0") "2.9"
          || throw "workstation-foundation: pkgs.harlequin ${pkgs.harlequin.version or "?"} predates hsql — the flake's overlays.default (the foundation domain's pin surface) must be applied (nixpkgs.overlays)";
        pkgs.harlequin
      )
      # the tailscale CLI on the home PATH (the daemon is the system
      # service on NixOS/darwin legs; tailscaled is the host-owned
      # prerequisite on any standalone leg)
    ]
    ++ lib.optionals config.workstation.foundation.tailscale.enable [ pkgs.tailscale ];

    # the hsql agent skill: the build-time-generated tree (above), served
    # as a declared entry symlink by the agent module — the activation
    # copy provision retired with the copy contract
    programs.hermes.skills.hsql = {
      enable = true;
      source = hsqlSkill;
    };

    # direnv + nix-direnv: the nix ecosystem's standard per-repo
    # environment layer (`use flake`/`use nix`, the evaluation cache, and
    # the GC roots that survive nix-collect-garbage between visits). The
    # HM module stages the direnv package and sources nix-direnv globally
    # (~/.config/direnv/lib/hm-nix-direnv.sh — direnv sources every lib
    # file before each .envrc). The shell hooks ride the fragment lane
    # (the starship precedent): HM's enableBash/enableZshIntegration write
    # into programs.bash/programs.zsh, which this substrate never enables
    # (the rc lane is the rendered home.file), so enabling those flags
    # would be a silent no-op — declared false to keep the intent loud.
    programs.direnv = {
      enable = true;
      nix-direnv.enable = true;
      enableBashIntegration = false;
      enableZshIntegration = false;
    };
  };
}
