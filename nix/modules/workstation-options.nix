# The workstation option declarations shared by every composition that loads
# the domain modules: the home leg (workstation-home.nix) and the report fold
# (nix/report.nix) both evaluate the co-located modules, so the options they
# SET live here, declared once (a module system needs the declaration before
# any setter).
{
  lib,
  ...
}:
{
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
  # the editor capability's language surface, set by the language
  # capabilities (modules/languages/*) and composed by the editor module —
  # the cross-capability contract, declared here so a language capability's
  # own evaluation carries it
  options.workstation.editor = {
    languages = lib.mkOption {
      type = lib.types.listOf (lib.types.attrsOf (lib.types.either lib.types.str (lib.types.listOf lib.types.str)));
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
}
