# The home plane: the capability modules plus the shared shell lane, the
# retire list, the workstation launcher and the switch driver.
{
  config,
  lib,
  pkgs,
  self,
  ...
}:
let
  cfg = config.workstation;

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
in
{
  imports = [ ../../modules ];

  options.workstation = {
    switch = {
      homeAttr = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The flake attr of this host's homeConfiguration: the switch driver's home-plane target.";
      };
      systemAttr = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "The flake attr of this host's system configuration: the switch driver's --system target.";
      };
    };

    shell.fragments = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            id = lib.mkOption {
              type = lib.types.str;
              description = "The fragment id: the file stem under .config/workstation/shell/.";
            };
            target = lib.mkOption {
              type = lib.types.str;
              description = "The home-relative rc file sourcing the fragment.";
            };
            marker = lib.mkOption {
              type = lib.types.str;
              description = "The guard comment marking managed content.";
            };
            payload = lib.mkOption {
              type = lib.types.path;
              description = "The fragment body.";
            };
            domain = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "The declaring domain: the tiebreak between domains sharing a slot.";
            };
            order = lib.mkOption {
              type = lib.types.int;
              description = "The slot on the rc lane, in round tens.";
            };
            trailing = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Compose after every domain's fragments.";
            };
          };
        }
      );
      default = [ ];
      description = "Shell fragments sourced from the rc files in (trailing, order, domain) order.";
    };

    retire = lib.mkOption {
      type = lib.types.listOf (
        lib.types.coercedTo lib.types.str (p: { path = p; }) (
          lib.types.submodule {
            options = {
              path = lib.mkOption {
                type = lib.types.str;
                description = "The home-relative tombstone path.";
              };
              recursive = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Remove the path as a directory tree.";
              };
            };
          }
        )
      );
      default = [ ];
      description = "Home-relative paths removed at activation, a receipt each in retire.log.";
    };
  };

  config = {
    home.activation.workstation-retire = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      lib.concatMapStrings (
        entry:
        let
          p = entry.path;
        in
        ''
          target="$HOME/${p}"
          verdict=absent
          if [ -e "$target" ] || [ -L "$target" ]; then
        ''
        + (
          if entry.recursive then
            ''
              rm -rf "$target"
              echo "workstation: retired ${p} (recursive)"
              verdict=removed-recursive
            ''
          else
            ''
              if [ -d "$target" ] && [ ! -L "$target" ]; then
                echo "workstation: retire SKIPPED (${p} is a directory — declare it with recursive = true, the consent, or remove it manually)"
                verdict=skipped-directory
              else
                rm -f "$target"
                echo "workstation: retired ${p}"
                verdict=removed
              fi
            ''
        )
        + ''
          fi
          mkdir -p "$HOME/.local/state/workstation"
          echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ${p} $verdict" >> "$HOME/.local/state/workstation/retire.log"
        ''
      ) cfg.retire
    );

    home.file =
      assert
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

    home.packages = [
      (pkgs.writeShellScriptBin "workstation" (
        "WORKSTATION_JQ=\${WORKSTATION_JQ:-${pkgs.jq}/bin/jq}\n"
        + builtins.readFile (self + "/bin/workstation")
      ))
      (import ../workstation-switch.nix {
        inherit pkgs;
        flake = self;
        homeAttr = cfg.switch.homeAttr;
        systemAttr = cfg.switch.systemAttr;
      })
    ];

    home.stateVersion = "25.05";
  };
}
