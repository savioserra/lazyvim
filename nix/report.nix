# The declared-state report: a fold over the co-located capability modules —
# the manifest walker's replacement (docs/absorption.md, decision 4). The
# capability walk (nix/lib/capabilities.nix) is the registry; every
# capability is evaluated once against home-manager and the fold reports the
# composed declared surface. No manifest exists; nothing here reads one.
#
# Report shape (the wire, consumed by the engine's baked release —
# nix/engine.nix — and by eval-time readers):
#   counts          { capabilities fileTargets claimTargets fragments retire }
#   fileTargetNames home-relative leaf targets declared by home.file
#   claimTargets    home-relative tree targets (store trees claimed at a
#                   home path — the entries declared recursive)
#   capabilityOrder capability ids, the walk's id sort (the declared order)
#   fragmentOrder   [ { target, fragments } ] — the declared rc lane, per
#                   target in composition order
#   accounting      per-capability rows: { id, foundation, fileTargets,
#                   claimTargets, fragments, retire }
#
# Classification law: an entry is classified by what its declaration says —
# `recursive = true` marks a tree claim; every other home.file key is a leaf
# target. home-manager's own generated entries (the systemd user units, the
# environment/dbus glue, the state keepers) are NOT declared state: the fold
# evaluates a module-free baseline and subtracts it, so the report carries
# only what the capabilities declare — and pins no home path (the baseline
# subtraction is also what keeps a host identity out of the bytes).
# The fragment lane's rendered files (.config/workstation/shell/<id>.sh and
# the sourced rc targets) are DERIVED by the lane, not declared targets:
# they are reported structurally through fragmentOrder and derived
# downstream, never listed here. HM-derived consequences of a declared
# option (the fontconfig targets the fonts capability's `enable` produces)
# belong to the declaring capability.
{
  lib,
  pkgs,
  # home-manager.lib — the module system the capability modules declare into
  hm,
  # the flake tree (modules/, nix/, workstation/ payloads resolve against it)
  treeRoot,
  # REQUIRED — no default may bake an identity (t_40cf3088). The eval's
  # home.homeDirectory; the report itself pins no home paths.
  homeDir,
}:
let
  capabilityWalk = import ./lib/capabilities.nix { inherit lib treeRoot; };

  foundationOf =
    id:
    let
      domain = builtins.head (lib.splitString "/" id);
    in
    if domain == "foundation" then "base"
    else if domain == "languages" then "runtime"
    else domain;

  # --- evaluation -----------------------------------------------------------
  # One home-manager evaluation per capability (the attribution fold), one
  # over all capabilities (the composed surface), and one module-free
  # baseline (the machinery subtraction). The evals load ONLY the domain
  # modules plus the shared option declarations — never the home leg's
  # rendering module — so the report sees the DECLARED surface, not the
  # rendered fragment files.
  evalModules = moduleFiles:
    (hm.homeManagerConfiguration {
      inherit pkgs;
      # the domain modules take `self` (the flake tree) beside the standard
      # module args
      extraSpecialArgs.self = treeRoot;
      modules = [
        (import (treeRoot + "/nix/modules/workstation-options.nix"))
        {
          home.username = "report";
          home.homeDirectory = homeDir;
          home.stateVersion = "25.05";
        }
      ] ++ moduleFiles;
    }).config;

  capabilityEvals = map (cap: evalModules cap.moduleFiles) capabilityWalk.capabilities;
  fullEval = evalModules capabilityWalk.moduleFiles;
  baselineEval = evalModules [ ];

  # home-manager's generated entries at this eval: the machinery the
  # capabilities never declared (subtracted below)
  baselineKeys = builtins.attrNames baselineEval.home.file;

  # home-relative keys only: home-manager generates some entries with
  # home-ABSOLUTE keys (the fontconfig conf.d files ride the evaluated
  # home path) — machinery, not declared state, and exactly the identity
  # leak the report must not carry (the report pins no home path)
  homeRelative = lib.filterAttrs (k: _: !(lib.hasPrefix "/" k));

  declaredHomeFile = eval:
    homeRelative
      (lib.filterAttrs (k: _: !(builtins.elem k baselineKeys)) eval.home.file);

  claimTargetsOf = eval: builtins.attrNames
    (lib.filterAttrs (_: v: v.recursive or false) (declaredHomeFile eval));
  leafTargetsOf = eval: builtins.attrNames
    (lib.filterAttrs (_: v: !(v.recursive or false)) (declaredHomeFile eval));

  # a capability's fragments as (id, target) pairs — the lane's declared unit
  fragmentPairsOf = eval:
    map (f: { id = f.id; target = f.target; }) eval.workstation.shell.fragments;

  capRow = id: eval: {
    inherit id;
    foundation = foundationOf id;
    fileTargets = leafTargetsOf eval;
    claimTargets = claimTargetsOf eval;
    fragments = fragmentPairsOf eval;
    retire = eval.workstation.retire;
  };

  rows = lib.sort (a: b: a.id < b.id)
    (lib.zipListsWith (cap: eval: capRow cap.id eval)
      capabilityWalk.capabilities capabilityEvals);

  # --- the composed surface (the full eval; order = the walk's id sort) ------
  fragments = fragmentPairsOf fullEval;
  fragmentOrder = map (t: {
    target = t;
    fragments = map (f: f.id)
      (builtins.filter (f: f.target == t) fragments);
  }) (lib.unique (map (f: f.target) fragments));

  fileTargetNames = leafTargetsOf fullEval;
  claimTargets = claimTargetsOf fullEval;
  retire = fullEval.workstation.retire;

  # --- the fold's integrity: nothing escaped classification ------------------
  # Structural assertions (never byte contracts): the union of the
  # per-capability surfaces must equal the composed surface, or a module
  # file was misclassified (a library swallowing a module would silently
  # shrink the report).
  sorted = xs: lib.sort (a: b: a < b) (lib.unique xs);
  unionOk =
    sorted (lib.concatMap (r: r.fileTargets ++ r.claimTargets) rows)
    == sorted (fileTargetNames ++ claimTargets);
  fragmentsOk =
    lib.all (f: builtins.elem f (lib.concatMap (r: r.fragments) rows)) fragments
    && lib.length (lib.concatMap (r: r.fragments) rows) == lib.length fragments;
  retireOk = sorted (lib.concatMap (r: r.retire) rows) == sorted retire;

  # the report pins no home path: every declared target is home-relative
  # (an absolute key is home-manager machinery that rode the evaluated
  # home — carrying it would bake an identity into the release)
  relativeOk =
    lib.all (t: !(lib.hasPrefix "/" t)) (fileTargetNames ++ claimTargets)
    && lib.all (row: lib.all (t: !(lib.hasPrefix "/" t) && t != "") row.retire) rows;

  counts = {
    capabilities = builtins.length capabilityWalk.capabilities;
    fileTargets = builtins.length fileTargetNames;
    claimTargets = builtins.length claimTargets;
    fragments = builtins.length fragments;
    retire = builtins.length retire;
  };
in
assert unionOk || throw "workstation-report: a capability's declared targets do not compose to the full eval's — a module file escaped the fold's classification";
assert fragmentsOk || throw "workstation-report: the capability fragments do not compose to the full eval's declared lane";
assert retireOk || throw "workstation-report: the capability tombstones do not compose to the full eval's retire list";
assert relativeOk || throw "workstation-report: a declared target is not home-relative — home-manager machinery rode the evaluated home into the report";
{
  inherit counts fileTargetNames claimTargets;
  capabilityOrder = capabilityWalk.ids;
  inherit fragmentOrder;
  # one row per capability: { id, foundation, fileTargets, claimTargets,
  # fragments, retire } — the declared surface attributed to its owner
  accounting = rows;
}
