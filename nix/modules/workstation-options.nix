# The workstation option declarations shared by every composition that loads
# the domain modules: the home leg (workstation-home.nix) and the report fold
# (nix/report.nix) both evaluate the co-located modules, so the options they
# SET live here, declared once (a module system needs the declaration before
# any setter).
#
# This module also RENDERS the hermes serving surface (the skill and
# extension entry symlinks + the adopt step): the options are SET by
# whichever capability owns the skill (agent: secrets; foundation: hsql),
# and this module — loaded by every composition that loads the domain
# modules, the report fold's per-capability evals included — renders each
# setter's entries, so the fold attributes every entry to the capability
# that set it and the composed surface stays the union of the per-capability
# rows. The baseline eval (no capability modules) sets nothing and renders
# nothing.
{
  config,
  lib,
  ...
}:
let
  # the enabled skills and extensions as entries: { path, source } — one
  # entry symlink each ("default" is HERMES_HOME itself; any other profile
  # is ~/.hermes/profiles/<name>)
  skillEntries = lib.flatten (
    lib.mapAttrsToList (
      name: skill:
      map (profile: {
        path =
          if profile == "default" then
            ".hermes/skills/${name}"
          else
            ".hermes/profiles/${profile}/skills/${name}";
        source = skill.source;
      }) skill.profiles
    ) (lib.filterAttrs (_: skill: skill.enable) config.programs.hermes.skills)
  );

  extensionEntries = lib.mapAttrsToList (name: extension: {
    path = ".hermes/plugins/${name}";
    source = extension.package;
  }) (lib.filterAttrs (_: extension: extension.enable) config.programs.hermes.extensions);

  entries = skillEntries ++ extensionEntries;
in
{
  options.workstation.shell.fragments = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          id = lib.mkOption {
            type = lib.types.str;
            description = "The fragment's unique id (the file stem under .config/workstation/shell/)";
          };
          target = lib.mkOption {
            type = lib.types.str;
            description = "The home-relative rc file this fragment is sourced from";
          };
          marker = lib.mkOption {
            type = lib.types.str;
            description = "The guard comment identifying workstation-managed content";
          };
          payload = lib.mkOption {
            type = lib.types.path;
            description = "The fragment body's store path";
          };
          order = lib.mkOption {
            type = lib.types.int;
            description = ''
              The fragment's slot in the rc lane's composition order. The
              order is PATH semantics (the user-local bin fragment must
              lead so later fragments resolve through it) and is never
              derived: declare it in round tens so a new fragment slots
              between neighbours without renumbering the lane. Two distinct
              ids may not share a slot and one id may not carry two — the
              composition fails the eval on either.
            '';
          };
        };
      }
    );
    default = [ ];
    description = ''
      The shell fragments: per-fragment files under
      .config/workstation/shell/ and the one sourced rc lane per target.
      Declared by the owning domain modules; ids must be unique; the rc
      lane sources them in the declared `order` (nix/lib/shell-lane.nix) —
      never the module system's merged list order, which is REVERSE module
      order and would flip PATH semantics silently.
    '';
  };

  # the declared retire list: legacy/foreign tombstones the generation
  # diff cannot remove (they predate the substrate or live in hot home).
  # One idempotent activation pass for the whole list, once per
  # generation, each outcome leaving a named receipt in the host's
  # workstation state log. A string entry is a file/symlink tombstone
  # (rm -f); { path; recursive = true; } is the declared consent that
  # removes a directory tree — rm -rf of exactly the declared path, and
  # nothing else. A directory met WITHOUT the consent is reported with
  # the fix named and skipped (the vps cutover, 2026-10-27: plain rm on
  # the nvm tree failed and the tombstone silently stayed).
  options.workstation.retire = lib.mkOption {
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
              description = ''
                The declared consent to remove the path as a directory
                tree at activation (rm -rf of exactly this path). Without
                it the hook removes only files and symlinks: a directory
                is reported with the fix named and skipped — never
                silently forced.
              '';
            };
          };
        }
      )
    );
    default = [ ];
    description = ''
      Home-relative paths to remove at activation (idempotent, a named
      receipt per outcome). A plain string is a file/symlink tombstone;
      recursive = true is the declared consent that removes a tree.
      Dropped once the fleet has switched past the tombstone.
    '';
  };
  # the agent capability's declared skills, set by the owning capabilities
  # (the agent module renders; foundation contributes hsql) — the
  # cross-capability contract, declared here so a capability's own
  # evaluation carries it. Each enabled skill renders ONE entry symlink per
  # target profile (hot-dir law: individual entries under the skills dir,
  # never the dir, never live state) — the copy contract's per-file leaves
  # retired with the format.
  options.programs.hermes.skills = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Serve this skill to the target profiles.";
          };
          profiles = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "default" ];
            description = ''
              The hermes profiles that receive the entry: "default" is
              HERMES_HOME itself (~/.hermes/skills), any other name is
              ~/.hermes/profiles/<name>/skills.
            '';
          };
          source = lib.mkOption {
            type = lib.types.path;
            description = ''
              The skill tree as a store path — an authored payload directory
              or a derivation that generates the skill from its tool (the
              hsql precedent: version-matched, offline).
            '';
          };
        };
      }
    );
    default = { };
    description = ''
      The hermes agent's declared skills: name -> { enable, profiles,
      source }. Rendered by the agent module as entry symlinks into each
      target profile's skills dir.
    '';
  };

  # the editor capability's language surface, set by the language
  # capabilities (modules/languages/*) and composed by the editor module —
  # the cross-capability contract, declared here so a language capability's
  # own evaluation carries it
  options.workstation.editor = {
    languages = lib.mkOption {
      type = lib.types.listOf (
        lib.types.attrsOf (lib.types.either lib.types.str (lib.types.listOf lib.types.str))
      );
      default = [ ];
      description = ''
        The language profile entries the editor composes into
        lua/languages/profile.lua: { id, requires?, lazyvim_extras?,
        plugin_module?, mason_packages? }. Language modules contribute
        theirs; entries compose in id order.
      '';
    };
    languagePlugins = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        Language plugin modules deployed to
        .config/nvim/lua/languages/plugins/ (file names preserved).
      '';
    };
  };

  # the hermes gateway extensions: the serving lane's other input (with
  # programs.hermes.skills above) — declared here so every composition
  # that loads the domain modules carries it; the agent module renders
  # through the shared lane below
  options.programs.hermes.extensions = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether the extension deploys into the gateway's extension surface";
          };
          package = lib.mkOption {
            type = lib.types.package;
            description = ''
              The gateway plugin tree as a derivation (the python-env
              pattern: buildPythonPackage or a python3.withPackages env
              joined with the plugin's files).
            '';
          };
        };
      }
    );
    default = { };
    description = ''
      Gateway extensions: name -> { enable, package }. Each enabled
      extension links as ONE entry symlink into ~/.hermes/plugins/<name>
      (user discovery outranks bundled); the dir itself stays hot.
    '';
  };

  # --- the hermes serving lane ---------------------------------------------
  config = {
    # the declared entry symlinks: ONE store symlink per skill per target
    # profile, and per extension into the user plugins dir (the hot-dir
    # law: individual entries, never the dir, never live state)
    home.file = builtins.listToAttrs (
      map (entry: lib.nameValuePair entry.path { source = entry.source; }) entries
    );

    # the adopt step: the copy contract makes way. Runs BEFORE the link
    # checks (HM's first DAG node): a declared entry path that still holds
    # a real tree — the retired copy contract's per-file links, a tool's
    # provision writes, runtime drift — is removed once, with a receipt, so
    # the first declarative generation can link. Idempotent: an existing
    # symlink never matches.
    home.activation.adopt-hermes-entries = lib.hm.dag.entryBefore [ "checkLinkTargets" ] (
      lib.concatMapStrings (entry: ''
        target="$HOME/${entry.path}"
        if [ -e "$target" ] && [ ! -L "$target" ]; then
          rm -rf "$target"
          mkdir -p "$HOME/.local/state/workstation"
          echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) adopt ${entry.path}" >> "$HOME/.local/state/workstation/retire.log"
          echo "workstation: adopted ${entry.path} — the copy-contract tree made way for the declared symlink"
        fi
      '') entries
    );
  };
}
