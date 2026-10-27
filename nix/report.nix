# The declared-state report: a fold over the co-located capability modules —
# the manifest walker's replacement (docs/absorption.md, decision 4). The
# capability walk (nix/lib/capabilities.nix) is the registry; every
# capability is evaluated once against home-manager and the fold reports the
# composed declared surface. No manifest exists; nothing here reads one.
#
# Report shape (the fold's raw record — the read verbs in flake.nix project
# it into workstation.report.<verb>, which `nix eval` and the workstation
# shim's read verbs serve):
#   counts          { capabilities fileTargets claimTargets fragments retire }
#   fileTargetNames home-relative leaf targets declared by home.file
#   claimTargets    home-relative tree targets (store trees claimed at a
#                   home path — the entries declared recursive)
#   capabilityOrder capability ids, the walk's id sort (the declared order)
#   fragmentOrder   [ { target, fragments } ] — the declared rc lane, per
#                   target in the declared order contract's order
#                   (nix/lib/shell-lane.nix — the fragments' `order` slots,
#                   not the module system's merged list order)
#   accounting      per-capability rows: { id, foundation, fileTargets,
#                   claimTargets, fragments, retire }
#   selectable      the walk-derived paths this machine can pin —
#                   <path> -> { kind (domain|member|baseline), baseline,
#                   default }; the shim's add|remove validate against it
#   selections      the machine's pins (hosts/selections.nix,
#                   nix/lib/selections.nix) and the resolved rows —
#                   <path> -> { state (on|off|baseline|unavailable), note };
#                   every eval here applies the pins, so the composed
#                   surface, the accounting and `plan` are this MACHINE's
#                   next-switch truth, not the bare substrate's
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
  # the flake tree (modules/, nix/ resolve against it)
  treeRoot,
  # REQUIRED — no default may bake an identity (t_40cf3088). The eval's
  # home.homeDirectory; the report itself pins no home paths.
  homeDir,
}:
let
  capabilityWalk = import ./lib/capabilities.nix { inherit lib treeRoot; };

  # the machine's capability selection: the pins file read and validated
  # through the shared library — the same validation the legs' translation
  # runs, so a hand-broken file fails every eval that could deploy it
  selectionsLib = import ./lib/selections.nix { inherit lib treeRoot; };
  selectionsFile = treeRoot + "/hosts/selections.nix";
  pins = selectionsLib.readPins selectionsFile;

  foundationOf =
    id:
    let
      domain = builtins.head (lib.splitString "/" id);
    in
    if domain == "foundation" then
      "base"
    else if domain == "languages" then
      "runtime"
    else
      domain;

  # --- evaluation -----------------------------------------------------------
  # One home-manager evaluation per capability (the attribution fold), one
  # over all capabilities (the composed surface), and one module-free
  # baseline (the machinery subtraction). The evals load ONLY the domain
  # modules plus the shared option declarations — never the home leg's
  # rendering module — so the report sees the DECLARED surface, not the
  # rendered fragment files. Every eval also applies this machine's
  # capability selection (nix/lib/selections.nix, hosts/selections.nix —
  # validated at read): the fold reports the machine's next-switch truth.
  # The bare form (selections = false) exists for the availability probe,
  # where a pin would out-vote the probe's forced flag through the bool
  # OR-merge.
  evalModules =
    {
      moduleFiles,
      selections ? true,
    }:
    (hm.homeManagerConfiguration {
      inherit pkgs;
      # the domain modules take `self` (the flake tree) beside the standard
      # module args
      extraSpecialArgs.self = treeRoot;
      modules = [
        (import (treeRoot + "/nix/modules/workstation-options.nix"))
      ]
      ++ lib.optionals selections [
        (selectionsLib.translationModule selectionsFile)
      ]
      ++ [
        {
          home.username = "report";
          home.homeDirectory = homeDir;
          home.stateVersion = "25.05";
        }
      ]
      ++ moduleFiles;
    });

  capabilityEvals = map (cap: (evalModules { moduleFiles = cap.moduleFiles; }).config) (
    capabilityWalk.capabilities
  );
  fullEvalSet = evalModules { moduleFiles = capabilityWalk.moduleFiles; };
  fullEval = fullEvalSet.config;
  # the option tree of the composed eval: the enable options' DECLARED
  # defaults (core domains on, language members off) — the translation may
  # pin paths either way; the defaults are what an unpinned path rides
  fullEvalOptions = fullEvalSet.options;
  baselineEval = (evalModules { moduleFiles = [ ]; }).config;

  # home-manager's generated entries at this eval: the machinery the
  # capabilities never declared (subtracted below)
  baselineKeys = builtins.attrNames baselineEval.home.file;

  # home-relative keys only: home-manager generates some entries with
  # home-ABSOLUTE keys (the fontconfig conf.d files ride the evaluated
  # home path) — machinery, not declared state, and exactly the identity
  # leak the report must not carry (the report pins no home path)
  homeRelative = lib.filterAttrs (k: _: !(lib.hasPrefix "/" k));

  declaredHomeFile =
    eval: homeRelative (lib.filterAttrs (k: _: !(builtins.elem k baselineKeys)) eval.home.file);

  claimTargetsOf =
    eval: builtins.attrNames (lib.filterAttrs (_: v: v.recursive or false) (declaredHomeFile eval));
  leafTargetsOf =
    eval: builtins.attrNames (lib.filterAttrs (_: v: !(v.recursive or false)) (declaredHomeFile eval));

  # a capability's fragments as (id, target) pairs — the lane's declared unit
  fragmentPairsOf =
    eval:
    map (f: {
      id = f.id;
      target = f.target;
    }) eval.workstation.shell.fragments;

  # the tombstones as home-relative paths — the hook's consent marker
  # (`recursive`) is activation machinery, never report surface
  retirePathsOf = eval: map (e: e.path) eval.workstation.retire;

  # the composed lane's order: the explicit order contract
  # (nix/lib/shell-lane.nix) — the ONE sort the home leg's rendered rc
  # files also read; the module system's merged list order is never it
  lane =
    (import ./lib/shell-lane.nix { inherit lib; }).sortedFragments
      fullEval.workstation.shell.fragments;
  fragments = map (f: {
    id = f.id;
    target = f.target;
  }) lane;

  capRow = id: eval: {
    inherit id;
    foundation = foundationOf id;
    fileTargets = leafTargetsOf eval;
    claimTargets = claimTargetsOf eval;
    fragments = fragmentPairsOf eval;
    retire = retirePathsOf eval;
  };

  rows = lib.sort (a: b: a.id < b.id) (
    lib.zipListsWith (cap: eval: capRow cap.id eval) capabilityWalk.capabilities capabilityEvals
  );

  # --- the composed surface (the full eval) ---------------------------------
  # (fragments/fragmentOrder bind above the capRow: the lane's explicit
  # order contract feeds the report's projection of the rc lane)
  fragmentOrder = map (t: {
    target = t;
    fragments = map (f: f.id) (builtins.filter (f: f.target == t) fragments);
  }) (lib.unique (map (f: f.target) fragments));

  fileTargetNames = leafTargetsOf fullEval;
  claimTargets = claimTargetsOf fullEval;
  retire = retirePathsOf fullEval;

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

  # --- the selection lens -----------------------------------------------------
  # The walk-derived selectable universe (domains + their members,
  # baseline-marked — nothing hardcoded) and this machine's resolved rows.
  # Availability is a MEMBER-level platform truth, probed by forcing the
  # path's enable option true vs false over its owning capabilities' module
  # files in BARE evals (pins excluded — a pin out-votes the probe through
  # the bool OR-merge); a flag that moves nothing here marks the path
  # unavailable (the nunchux darwin case). Domains are platform-neutral in
  # this substrate — every domain-level module deploys on both legs — so
  # only members probe; a future platform-gated domain extends the probe.
  selectablePaths = lib.sort (a: b: a < b) (
    lib.unique (selectionsLib.domains ++ selectionsLib.members)
  );

  defaultOf =
    path:
    (lib.getAttrFromPath (
      [ "workstation" ] ++ lib.splitString "/" path ++ [ "enable" ]
    ) fullEvalOptions).default;

  # the probe's comparison unit: a capability eval's whole declared surface,
  # flattened to comparable strings (targets, claims, fragment id/target
  # pairs, tombstones, package names, the editor's composed language ids)
  probeUnit =
    eval:
    lib.sort (a: b: a < b) (
      leafTargetsOf eval
      ++ claimTargetsOf eval
      ++ map (f: "${f.target}/${f.id}") eval.workstation.shell.fragments
      ++ retirePathsOf eval
      ++ map (p: p.name) eval.home.packages
      ++ map (e: e.id) eval.workstation.editor.languages
    );

  capabilitiesOfPath =
    path:
    builtins.filter (
      cap:
      cap.id == path
      || (lib.length (lib.splitString "/" cap.id) == 2 && lib.head (lib.splitString "/" cap.id) == path)
    ) capabilityWalk.capabilities;

  available =
    path:
    if selectionsLib.pathKind path != "member" then
      true
    else
      let
        files = lib.concatMap (cap: cap.moduleFiles) (capabilitiesOfPath path);
        forceEnable =
          value:
          (evalModules {
            moduleFiles = files ++ [
              {
                workstation = lib.setAttrByPath (lib.splitString "/" path ++ [ "enable" ]) value;
              }
            ];
            selections = false;
          }).config;
      in
      probeUnit (forceEnable true) != probeUnit (forceEnable false);

  # dependency notes: what a remove takes with it — copy, not logic; a path
  # absent here renders an empty note
  selectionNotes = {
    editor = "off: nvim and the composed language profile leave; the theme token path keeps serving tmux";
    fonts = "off: the nerd font and its fontconfig discovery leave";
    secrets = "off: the op CLI and its env fragment leave";
    agent = "off: the hermes runtime stack and the served skills leave";
    theme = "off: the deployed token path leaves (the theme library stays available to consumers)";
    terminal = "off: tmux and nunchux leave";
    "terminal/tmux" = "off: the tmux config, the plugin set and the pin manifest leave";
    "terminal/nunchux" = "off: the nunchux checkout and its rendered config leave";
    languages = "the domain shell deploys nothing itself — the members are the granularity";
  };

  noteOf =
    path:
    let
      kind = selectionsLib.pathKind path;
    in
    if kind == "baseline" then
      "baseline: always on"
    else if kind == "member" && lib.head (lib.splitString "/" path) == "languages" then
      "off: the toolchain and its editor profile entry leave"
    else
      selectionNotes.${path} or "";

  stateOf =
    path:
    if selectionsLib.pathKind path == "baseline" then
      "baseline"
    else
      let
        avail = available path;
        on = builtins.elem path pins.enable || (!(builtins.elem path pins.disable) && defaultOf path);
      in
      if on then
        (if avail then "on" else "unavailable")
      else if avail then
        "off"
      else
        "unavailable";

  selectable = builtins.listToAttrs (
    map (
      path:
      lib.nameValuePair path {
        kind = selectionsLib.pathKind path;
        baseline = selectionsLib.pathKind path == "baseline";
        # the baseline carries no enable option — it is always on
        default = selectionsLib.pathKind path != "baseline" && defaultOf path;
      }
    ) selectablePaths
  );

  selections = {
    pins = {
      inherit (pins)
        enable
        disable
        ;
    };
    rows = builtins.listToAttrs (
      map (
        path:
        lib.nameValuePair path {
          state = stateOf path;
          note = noteOf path;
        }
      ) selectablePaths
    );
  };
in
assert
  unionOk
  || throw "workstation-report: a capability's declared targets do not compose to the full eval's — a module file escaped the fold's classification";
assert
  fragmentsOk
  || throw "workstation-report: the capability fragments do not compose to the full eval's declared lane";
assert
  retireOk
  || throw "workstation-report: the capability tombstones do not compose to the full eval's retire list";
assert
  relativeOk
  || throw "workstation-report: a declared target is not home-relative — home-manager machinery rode the evaluated home into the report";
{
  inherit
    counts
    fileTargetNames
    claimTargets
    retire
    selectable
    selections
    ;
  capabilityOrder = capabilityWalk.ids;
  inherit fragmentOrder;
  # one row per capability: { id, foundation, fileTargets, claimTargets,
  # fragments, retire } — the declared surface attributed to its owner
  accounting = rows;
}
