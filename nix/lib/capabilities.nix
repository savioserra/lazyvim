# The capability walk: the filesystem is the registry (docs/absorption.md,
# decision 6). One walk, two consumers — the report fold (nix/report.nix)
# and the home leg's module imports (nix/modules/workstation-home.nix) — so
# the composed surface and its report can never disagree about which modules
# exist or in what order they compose.
#
# A capability is a directory under modules/ whose own files carry at least
# one .nix file (the languages nest one level deeper). The id is the path
# relative to modules/; the composition order is the walk's id sort — the
# declared order, reviewed in diffs. A capability's .nix files split into
# home-manager MODULES (the capability's declarations) and non-module files
# (libraries and data — theme.nix, skills.nix): a file is a module when
# importing it with the module argset yields a module shape (an attrset
# whose keys are module keys), so a library can never enter a module list.
{
  lib,
  # the flake tree (modules/ resolves against it)
  treeRoot,
}:
let
  modulesRoot = treeRoot + "/modules";

  walk =
    rel:
    let
      dir = modulesRoot + (if rel == "" then "" else "/${rel}");
      entries = builtins.readDir dir;
      names = builtins.attrNames entries;
      nixFiles = builtins.filter (n: entries.${n} == "regular" && lib.hasSuffix ".nix" n) names;
      subdirs = builtins.filter (n: entries.${n} == "directory") names;
      here = if nixFiles == [ ] then [ ] else [
        {
          id = rel;
          files = map (n: dir + "/${n}") nixFiles;
        }
      ];
    in
    here ++ lib.concatLists (map (n: walk (if rel == "" then n else "${rel}/${n}")) subdirs);

  # The module-argset probe: a module file imports cleanly with the standard
  # module args and returns module-shaped attrs; libraries (exact-arg
  # functions like theme.nix) die on the probe or return foreign shapes.
  # The probe's pkgs placeholder is deliberately not a real package set —
  # module bodies stay lazy through the probe (only the result's attrset
  # shape is forced), and a real pkgs here would make the walk force the
  # module system's pkgs argument (infinite recursion in imports resolution:
  # the home leg runs this walk while its own imports are being resolved).
  # An arg outside the standard module set throws: a module the probe cannot
  # name is a classification failure, never a silent library.
  probeArg =
    name:
    {
      "lib" = lib;
      "pkgs" = null;
      "self" = treeRoot;
      "config" = { };
      "options" = { };
      "modules" = [ ];
      "specialArgs" = { };
    }
    .${name} or (throw "workstation-capabilities: module argument '${name}' is outside the standard module set — the capability probe cannot classify this file");

  moduleKeys = [ "options" "config" "imports" "_file" "_class" "key" "disabledModules" "meta" ];

  isModuleFile =
    file:
    let
      imported = import file;
      probe =
        if !(builtins.isFunction imported) then null
        else imported (builtins.mapAttrs (n: _: probeArg n) (builtins.functionArgs imported));
      attempt = if probe == null then null else builtins.tryEval probe;
      value = if attempt == null || !attempt.success then null else attempt.value;
    in
    builtins.isAttrs value
    && builtins.all (k: builtins.elem k moduleKeys) (builtins.attrNames value)
    && builtins.elem "config" (builtins.attrNames value);

  capabilities = lib.sort (a: b: a.id < b.id)
    (map (cap: cap // { moduleFiles = builtins.filter isModuleFile cap.files; }) (walk ""));
in
{
  # capability ids in composition order (the walk's id sort)
  ids = map (cap: cap.id) capabilities;

  # every capability's home-manager module files, in composition order
  moduleFiles = lib.concatMap (cap: cap.moduleFiles) capabilities;

  # per-capability module files (the attribution fold's eval units)
  inherit capabilities;
}
