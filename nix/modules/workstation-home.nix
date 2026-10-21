# The home leg: home-manager CONSUMES the real manifests.
#
# The file plane (chezmoi file/symlink + download trees + git checkouts),
# the fragment plane (per-owner fragment files + one sourced rc lane,
# topo order from the manifests) and the daemon user unit are derived
# inside the walker; this module only assembles them into HM options and
# carries the two decisions that are NOT renderable data:
#   - .local/bin/nvim -> the nixpkgs neovim (nvim-profile lane replaces
#     the bootstrap pin; the payload's own link is removed loudly)
#   - the daemon unit binds the REAL engine derivation (P0's mixRelease)
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
  ws = import ../manifest-lib.nix {
    inherit lib pkgs;
    treeRoot = self;
  };

  # The nvim-profile lane overrides the payload's bootstrap pin with the
  # nixpkgs neovim. The payload MUST still declare the link — if the
  # package tree stops declaring it, this override has to be revisited
  # (drift guard, loud on both sides). The guard lives INSIDE config: a
  # top-level assert would force `ws` (and with it the pkgs module arg)
  # during module fixup, re-entering _module.args.pkgs — infinite
  # recursion in the HM standalone module system.
  nvimTarget = ".local/bin/nvim";

  fragmentFiles = builtins.foldl'
    (acc: x:
      acc // builtins.listToAttrs (map
        (id:
          let f = ws.fragmentsById.${id};
          in {
            name = ".config/workstation/shell/${id}.sh";
            value.text = "${f.marker}\n${f.body}\n";
          })
        x.frags))
    { } ws.fragmentOrder;

  # the one sourced rc lane: each rc target sources its fragment files in
  # topo order (the manifests' order IS the shell contract)
  rcFiles = builtins.listToAttrs (map (x: {
    name = x.t;
    value.text = lib.concatStrings (map (id:
      let f = ws.fragmentsById.${id};
      in "${f.marker}\n[ -r \"$HOME/.config/workstation/shell/${id}.sh\" ] && . \"$HOME/.config/workstation/shell/${id}.sh\"\n")
      x.frags);
  }) ws.fragmentOrder);

  # symlink entries whose source came back as a home-absolute string are
  # intra-home links; store-path sources pass straight through
  homeFileSources = ws.fileTargets // fragmentFiles // rcFiles;
in
{
  options.workstation.report = {
    counts = lib.mkOption { type = lib.types.attrs; readOnly = true; };
    fileTargets = lib.mkOption { type = lib.types.listOf lib.types.str; readOnly = true; };
    claimTargets = lib.mkOption { type = lib.types.listOf lib.types.str; readOnly = true; };
    fragmentOrder = lib.mkOption { type = lib.types.listOf lib.types.attrs; readOnly = true; };
    packageOrder = lib.mkOption { type = lib.types.listOf lib.types.str; readOnly = true; };
    accounting = lib.mkOption { type = lib.types.listOf lib.types.attrs; readOnly = true; };
    daemonUnit = lib.mkOption { type = lib.types.str; readOnly = true; };
  };

  config = {
    # --- the file plane: real manifests -> home.file -----------------------
    # intra-home link sources come back as absolute strings; HM store
    # sources must be paths, so they wrap in mkOutOfStoreSymlink (text
    # entries — fragments and the rc lane — carry no source and pass as-is)
    home.file =
      (builtins.mapAttrs (_: v:
        if v ? source && lib.isString v.source then {
          source = config.lib.file.mkOutOfStoreSymlink v.source;
        } else v) homeFileSources)
      // (builtins.listToAttrs (map (c: {
        name = c.target;
        value.source = c.source;
      }) ws.claimsOut))
      // (if ws.fileTargets ? ${nvimTarget}
        then {
          # nvim-profile lane: the nixpkgs neovim replaces the bootstrap pin
          ${nvimTarget}.source = "${pkgs.neovim}/bin/nvim";
        }
        else throw "workstation-nix: the payload no longer declares '${nvimTarget}' — the nvim-profile lane override must be revisited");

    # the walker's platform coverage for fonts (fc-cache picks up
    # ~/.local/share/fonts; keep the cache fresh)
    fonts.fontconfig.enable = true;

    # --- the daemon: pubsub/overlay/theme as a user service ---------------
    systemd.user.services.workstation-daemon = {
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
        config.systemd.user.services.workstation-daemon.Service.ExecStart;
    };

    home.stateVersion = "25.05";
  };
}
