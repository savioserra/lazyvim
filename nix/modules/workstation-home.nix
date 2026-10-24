# The home leg: home-manager CONSUMES the real manifests.
#
# The file plane (chezmoi file/symlink + download trees + git checkouts),
# the fragment plane (per-owner fragment files + one sourced rc lane,
# topo order from the manifests) and the daemon user unit are derived
# inside the walker; this module only assembles them into HM options and
# carries the two decisions that are NOT renderable data:
#   - .local/bin/nvim -> the nixpkgs neovim (nvim-profile lane replaces
#     the bootstrap pin; the payload's own link is removed loudly)
#   - the daemon unit binds the REAL engine derivation (the build gate's
#     mixRelease)
# The report passthrough exists so `nix eval` can read the derived
# surface without building anything.
{
  config,
  lib,
  pkgs,
  self,
  engine,
  ...
}:
let
  cfg = config.workstation;

  ws = import ../manifest-lib.nix {
    inherit lib pkgs;
    # the host's home — HM's own option, set by the per-host config
    # (hosts/<host>/default.nix or the standalone module). The walker
    # accepts no baked default: identity flows from the host or eval dies.
    homeDir = config.home.homeDirectory;
    treeRoot = self;
  };
  # the nvim-profile lane's bin target — retired with the lane itself (the
  # editor module owns .local/bin/nvim now)

  # the native shell lane: the owning domain modules declare their
  # fragments (id, target, marker, payload) on workstation.shell.fragments;
  # the aggregate renders — a fragment file per id (marker + body) and one
  # rc file per target sourcing them in the declared order (the explicit
  # contract the walker's derived topo walk used to be)
  fragmentFiles = builtins.foldl'
    (acc: f: acc // {
      ".config/workstation/shell/${f.id}.sh".text =
        "${f.marker}\n${builtins.readFile f.payload}";
    })
    { } cfg.shell.fragments;

  rcFiles = builtins.foldl'
    (acc: f: acc // {
      ${f.target}.text = (acc.${f.target}.text or "") + "${f.marker}\n" + ''
        [ -r "$HOME/.config/workstation/shell/${f.id}.sh" ] && . "$HOME/.config/workstation/shell/${f.id}.sh"
      '';
    })
    (builtins.listToAttrs (map (t: lib.nameValuePair t { text = ""; })
      (lib.unique (map (f: f.target) cfg.shell.fragments))))
    cfg.shell.fragments;

  # symlink entries whose source came back as a home-absolute string are
  # intra-home links; store-path sources pass straight through
  homeFileSources = ws.fileTargets // fragmentFiles // rcFiles;
in
{
  # --- the co-located domain modules ---------------------------------------
  # the native substrate: each module declares its capability at its final
  # address (modules/<domain>/). The manifest walker below shrinks as each
  # capability's manifest dies in the same commit that lands its module —
  # never double-rendered.
  imports = [
    ../../modules/agent/agent.nix
    ../../modules/editor/editor.nix
    ../../modules/foundation/foundation.nix
    ../../modules/fonts/fonts.nix
    ../../modules/languages/go/go.nix
    ../../modules/languages/node/node.nix
    ../../modules/languages/typescript/typescript.nix
    ../../modules/secrets/secrets.nix
    ../../modules/terminal/terminal.nix
  ];

  options.workstation.report = {
    counts = lib.mkOption { type = lib.types.attrs; readOnly = true; };
    fileTargets = lib.mkOption { type = lib.types.listOf lib.types.str; readOnly = true; };
    claimTargets = lib.mkOption { type = lib.types.listOf lib.types.str; readOnly = true; };
    fragmentOrder = lib.mkOption { type = lib.types.listOf lib.types.attrs; readOnly = true; };
    packageOrder = lib.mkOption { type = lib.types.listOf lib.types.str; readOnly = true; };
    accounting = lib.mkOption { type = lib.types.listOf lib.types.attrs; readOnly = true; };
    daemonUnit = lib.mkOption { type = lib.types.str; readOnly = true; };
  };

  options.workstation.switch = {
    homeAttr = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        The flake attr of this host's homeConfiguration (e.g. "shyylol@wsl")
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

  # the declared retire list: legacy/foreign tombstones the generation
  # diff cannot remove (they predate the substrate or live in hot home).
  # One idempotent activation rm -f for the whole list, once per
  # generation, each removal leaving a named receipt in the host's
  # workstation state log.
  options.workstation.retire = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = ''
      Home-relative paths to remove at activation (idempotent rm -f, a
      named receipt per removal). Dropped once the fleet has switched
      past the tombstone.
    '';
  };

  # the shell fragment lane: the owning modules declare their fragments
  # (id, target, marker, payload); THIS module renders — the single
  # writer per fragment file and rc target. The order is the declared
  # list (module import order, then each module's own list order) — the
  # explicit contract the walker's derived topo walk used to be.
  options.workstation.shell.fragments = lib.mkOption {
    type = lib.types.listOf (lib.types.submodule {
      options = {
        id = lib.mkOption { type = lib.types.str; };
        target = lib.mkOption { type = lib.types.str; };
        marker = lib.mkOption { type = lib.types.str; };
        payload = lib.mkOption { type = lib.types.path; };
      };
    });
    default = [ ];
    description = ''
      The shell fragments: per-fragment files under
      .config/workstation/shell/ and the one sourced rc lane per target.
      Declared by the owning domain modules; ids must be unique.
    '';
  };

  config = {
    # --- the declared retire list (workstation.retire) ---------------------
    home.activation.workstation-retire = lib.hm.dag.entryAfter [ "writeBoundary" ]
      (lib.concatMapStrings (p: ''
        if [ -e "$HOME/${p}" ] || [ -L "$HOME/${p}" ]; then
          rm -f "$HOME/${p}"
          echo "workstation: retired ${p}"
        else
          echo "workstation: retire no-op (${p} absent)"
        fi
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ${p}" >> "$HOME/.local/state/workstation/retire.log"
      '') cfg.retire);

    # --- the file plane: real manifests -> home.file -----------------------
    # intra-home link sources come back as absolute strings; HM store
    # sources must be paths, so they wrap in mkOutOfStoreSymlink (text
    # entries — fragments and the rc lane — carry no source and pass as-is)
    home.file =
      assert
        # the lane's integrity: one fragment per (id, target) pair — two
        # owners of one pair would silently overwrite each other's body
        lib.length (lib.unique (map (f: [ f.id f.target ]) cfg.shell.fragments))
        == lib.length cfg.shell.fragments
        || throw "workstation-shell: duplicate fragment id/target pairs in the declared lane";
      (builtins.mapAttrs (_: v:
        if v ? source && lib.isString v.source then {
          source = config.lib.file.mkOutOfStoreSymlink v.source;
        } else v) homeFileSources)
      // (builtins.listToAttrs (map (c: {
        name = c.target;
        value.source = c.source;
      }) ws.claimsOut))
      // fragmentFiles
      // rcFiles;
    # (.local/bin/nvim moved to modules/editor/editor.nix — the nvim
    # manifest's death in the same commit retired the walker's override
    # guard with it)

    # (the fontconfig discovery moved to modules/fonts/fonts.nix with the
    # fonts manifest's death)

    # --- the write plane: workstation-switch, the nix-switch driver -------
    # Thin wrappers around home-manager switch / nixos-rebuild switch whose
    # publish step is how the daemon hears a generation switch (the
    # `system` overlay domain). Baked: this generation's engine and flake
    # snapshot, plus the host's two flake attrs; every value is overridable
    # by env (the driver's header documents the seams).
    home.packages = [
      (import ../workstation-switch.nix {
        inherit pkgs engine;
        flake = self;
        homeAttr =
          if cfg.switch.homeAttr != null then cfg.switch.homeAttr else "UNCONFIGURED-workstation.switch.homeAttr";
        systemAttr =
          if cfg.switch.systemAttr != null then
            cfg.switch.systemAttr
          else
            "UNCONFIGURED-workstation.switch.systemAttr";
      })
    ];

    # --- the daemon: pubsub/overlay/theme as a user service ---------------
    # A systemd USER unit — the Linux shape (NixOS-WSL, the VM). The darwin
    # leg has no systemd (launchd is the user-manager there); HM's
    # systemd.user surface is Linux-only, so the unit is gated, not the
    # whole substrate.
    systemd.user.services.workstation-daemon = lib.mkIf pkgs.stdenv.isLinux {
      Unit = {
        Description = "Workstation daemon (pubsub, overlay domains, theme, reads)";
      };
      Service = {
        ExecStart = "${engine}/bin/workstation daemon";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "default.target" ];
    };

    # --- report passthroughs (eval-only reads) ----------------------------
    workstation.report = {
      counts = ws.counts;
      fileTargets = ws.report.fileTargetNames;
      claimTargets = ws.report.claimTargets;
      fragmentOrder = ws.fragmentOrder;
      packageOrder = ws.report.packageOrder;
      accounting = ws.accounting;
      daemonUnit =
        config.systemd.user.services.workstation-daemon.Service.ExecStart
        or "linux-only (the darwin leg runs launchd)";
    };

    home.stateVersion = "25.05";
  };
}
