# The home leg: the co-located capability modules declare, this module
# renders the shared lanes.
#
# The domain modules (modules/<domain>/) own their file planes natively —
# home.file, the shell fragment lane's DECLARED list, the retire tombstones.
# This module assembles the fragment lane's rendered shape (a fragment file
# per id and one sourced rc file per target), stages the workstation client
# (the launcher shim from bin/workstation, plus this generation's flake
# snapshot at ~/.local/opt/workstation/flake — the shim's read verbs eval
# the report from exactly the tree this generation shipped) and the switch
# driver. There is no resident engine process and no baked report: reads
# are nix evals over the flake, and the switch-time receipt lands in the
# state tree's switch.log.
# The declared-state report is the fold's (workstation.report — nix/report.nix),
# answered by eval, never staged.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.workstation;

  # the native shell lane: the owning domain modules declare their
  # fragments (id, target, marker, payload, order) on
  # workstation.shell.fragments; the aggregate renders — a fragment file
  # per id (marker + body) and one rc file per target sourcing them in the
  # DECLARED order (the explicit order contract, nix/lib/shell-lane.nix —
  # never the module system's merged list order, which is REVERSE module
  # order)
  shellLane = import ../lib/shell-lane.nix { inherit lib; };
  lane = shellLane.sortedFragments cfg.shell.fragments;

  fragmentFiles = builtins.foldl' (
    acc: f:
    acc
    // {
      ".config/workstation/shell/${f.id}.sh".text = "${f.marker}\n${builtins.readFile f.payload}";
    }
  ) { } lane;

  rcFiles =
    builtins.foldl'
      (
        acc: f:
        acc
        // {
          ${f.target}.text =
            (acc.${f.target}.text or "")
            + "${f.marker}\n"
            + ''
              [ -r "$HOME/.config/workstation/shell/${f.id}.sh" ] && . "$HOME/.config/workstation/shell/${f.id}.sh"
            '';
        }
      )
      (builtins.listToAttrs (
        map (t: lib.nameValuePair t { text = ""; }) (lib.unique (map (f: f.target) lane))
      ))
      lane;
  # the module list comes from the shared capability walk
  # (nix/lib/capabilities.nix) — the same registry the report fold reads,
  # so the composed surface and its report can never disagree about which
  # modules exist; the FRAGMENT lane's order is its own explicit contract
  # (the order field, sorted by nix/lib/shell-lane.nix) — both the rc
  # files above and the report's fragmentOrder read that one sort
  capabilityWalk = import ../lib/capabilities.nix {
    inherit lib;
    treeRoot = self;
  };
in
{
  # --- the co-located domain modules ---------------------------------------
  # the native substrate: each module declares its capability at its final
  # address (modules/<domain>/) — imported through the shared walk, never a
  # hand-kept list.
  imports = [ ./workstation-options.nix ] ++ capabilityWalk.moduleFiles;

  options.workstation.switch = {
    homeAttr = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        The flake attr of this host's homeConfiguration (e.g. "<user>@<host>")
        — the workstation-switch driver's default home-plane target.
      '';
    };
    systemAttr = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        The flake attr of this host's nixosConfiguration (e.g. "wsl") —
        the workstation-switch driver's default --system target.
      '';
    };
  };

  # the shell fragment lane and the tombstone list are DECLARED once in
  # workstation-options.nix (the report fold's evals load the same
  # declarations); this module renders the lane.

  config = {
    # --- the declared retire list (workstation.retire) ---------------------
    home.activation.workstation-retire = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      lib.concatMapStrings (p: ''
        if [ -e "$HOME/${p}" ] || [ -L "$HOME/${p}" ]; then
          rm -f "$HOME/${p}"
          echo "workstation: retired ${p}"
        else
          echo "workstation: retire no-op (${p} absent)"
        fi
        # the receipt log's home (a fresh home has no state tree yet —
        # the activation runs first)
        mkdir -p "$HOME/.local/state/workstation"
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ${p}" >> "$HOME/.local/state/workstation/retire.log"
      '') cfg.retire
    );

    # --- the file plane: the modules' declared targets + the fragment lane +-
    # the generation's flake snapshot (the shim's read flake — the last
    # resort of its resolution order; a checkout or an explicit --flake
    # outranks it)
    home.file =
      assert
        # the lane's integrity: one fragment per (id, target) pair — two
        # owners of one pair would silently overwrite each other's body
        lib.length (
          lib.unique (
            map (f: [
              f.id
              f.target
            ]) cfg.shell.fragments
          )
        ) == lib.length cfg.shell.fragments
        || throw "workstation-shell: duplicate fragment id/target pairs in the declared lane";
      fragmentFiles
      // rcFiles
      // {
        ".local/opt/workstation/flake".source = self;
      };
    # (.local/bin/nvim moved to modules/editor/editor.nix — the nvim
    # manifest's death in the same commit retired the walker's override
    # guard with it)

    # (the fontconfig discovery moved to modules/fonts/fonts.nix with the
    # fonts manifest's death)

    # --- the client lane: the launcher shim + this generation's flake ------
    # The shim (bin/workstation at the repo tree — the same bytes the
    # repo's own checkout runs) is staged on PATH as a derivation; the
    # flake snapshot lands at ~/.local/opt/workstation/flake so the shim's
    # read verbs eval the report from exactly the tree this generation
    # shipped (the resolution order's last resort — a checkout or an
    # explicit --flake outranks it). The switch driver receives the leg's
    # default attrs VERBATIM — a leg that stages no default for a plane
    # (the mac leg's home plane) gets a driver that fails closed naming
    # the fix, never a sentinel attr that looks switchable.
    home.packages = [
      (pkgs.writeShellScriptBin "workstation" (builtins.readFile (self + "/bin/workstation")))
      (import ../workstation-switch.nix {
        inherit pkgs;
        flake = self;
        homeAttr = cfg.switch.homeAttr;
        systemAttr = cfg.switch.systemAttr;
      })
    ];

    # the shell fragment lane and the retire list are DECLARED by the domain
    # modules (workstation-options.nix) and rendered above

    home.stateVersion = "25.05";
  };
}
