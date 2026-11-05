# The base shell environment: the rc lane + fd, rg, lazygit (floored),
# mise, whiptail, direnv + nix-direnv. Fragments are payload files beside
# this module; the lane sorts by (target, domain, order) -
# nix/lib/shell-lane.nix.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  # the foundation tools ride nixpkgs, each floored at a minimum version:
  # the pinned 25.05 set predates the floors, so the pin-override overlay
  # must apply — an unapplied overlay or a lagging lock fails here.
  floored =
    name: floor: pkg:
    assert
      lib.versionAtLeast (pkg.version or "0") floor
      || throw "workstation-foundation: pkgs.${name} ${pkg.version or "?"} predates the floor ${floor} — the flake's overlays.default (the foundation domain's pin surface) must be applied (nixpkgs.overlays) and its lock must carry the version";
    pkg;
  tools = {
    fd = floored "fd" "10.4.2" pkgs.fd;
    ripgrep = floored "ripgrep" "15.2.0" pkgs.ripgrep;
    lazygit = floored "lazygit" "0.63.1" pkgs.lazygit;
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
    domain = "foundation";
    payload = ./fragments + "/${id}.sh";
  };

  # the declared list: the rc contract's slots, per target (the retired
  # mise and nvm fragments' slots stay retired — 30 is the secrets domain's
  # op-env slot)
  fragments = [
    (frag "user-local-bin" 10 "# workstation: managed user-local bin")
    (frag "managed-profile" 20 "# workstation: load managed profile")
    # the editor env defaults (EDITOR/VISUAL/GIT_EDITOR=nvim): substrate
    # facts — the editor domain's nvim IS the workstation editor, so the
    # env rides the managed shell environment on every rc target (a
    # capability naming a tool declares its env)
    (frag "managed-editor-env" 70 "# workstation: managed editor env")
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
    managed-editor-env = [
      ".profile"
      ".bashrc"
      ".zshrc"
    ];
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
      domain = f.domain;
      marker = f.marker;
      payload = f.payload;
    }) fragmentTargets.${f.id}
  ) fragments;

  # the starship config payload, co-located beside this module (the
  # dissolved prompt capability's bytes live with their owner)
  starshipToml = ./starship.toml;

  # the operator's shell extras as the fragment payload: the declared text
  # itself as a store source path (builtins.toFile — a plain store path, no
  # derivation) — the lane's renderer reads it back and guards it with the
  # fragment marker. Empty extras never reach this binding (the fragment
  # list is gated on the option above).
  operatorExtras = builtins.toFile "workstation-operator-extras" config.workstation.foundation.shell.extras;

in
{
  options.workstation.foundation = {
    shell.extras = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        The operator's shell lines (the stty -ixon class): per-machine
        interactive preferences with no substrate opinion, declared in the
        identity file (hosts/identity.nix, shellExtras — the ONLY per-host
        surface) and wired by the host legs. Rendered as the rc lane's
        trailing override (the lane's LAST fragment, .bashrc/.zshrc,
        marker-guarded — the renderer composes it after every domain's
        lane) so the operator's lines may override the managed ones; every
        switch re-renders them, so the prefs hold across applies. Empty
        (the template) renders no fragment and leaves the lane exactly
        managed.
      '';
    };
  };

  config = {
    # the shell lane: this domain's fragments in the declared order, plus
    # the operator's extras fragment when the machine declares any — the
    # payload is the extras text itself (a store source path), rendered
    # with the lane's marker guard
    workstation.shell.fragments =
      fragmentEntries
      ++ lib.optionals (config.workstation.foundation.shell.extras != "") [
        {
          target = ".bashrc";
          id = "operator-extras";
          order = 100;
          domain = "foundation";
          # the operator's override rank: the lane's trailing key composes
          # this after every domain's fragments — the documented contract
          # (a slot number alone cannot: any other domain's lane would
          # outrank or be outranked by the string comparison)
          trailing = true;
          marker = "# workstation: operator extras";
          payload = operatorExtras;
        }
        {
          target = ".zshrc";
          id = "operator-extras";
          order = 100;
          domain = "foundation";
          trailing = true;
          marker = "# workstation: operator extras";
          payload = operatorExtras;
        }
      ];

    home.file = {
      ".config/starship.toml".source = starshipToml;
    };

    home.packages = [
      # the foundation tools: nixpkgs-owned, floored at the retired
      # download pins' versions (the floors above make an unapplied
      # overlay or a lagging lock die at eval — a quiet downgrade of the
      # fleet's tool set is never a silent act)
      tools.fd
      tools.ripgrep
      tools.lazygit
      # mise: the nixpkgs binary only (`mise use`, `.mise.toml`, `mise x`);
      # no managed data dir, launcher or activation fragment — `mise
      # activate` is operator opt-in.
      pkgs.mise
      # whiptail (the newt package): the launcher shim's install-time UI —
      # `workstation init` captures the machine's identity through whiptail
      # dialogs prefilled with the detected values. A prerequisite of the
      # bin surface, shipped by the substrate so every managed host has it.
      pkgs.newt
    ];

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
