# The per-machine capability selection: hosts/selections.nix pins the
# machine's capability flags over the declared defaults. The verb grammar is
# the file grammar — `workstation add|remove <path>` writes list rows, the
# eval reads them back:
#
#   {
#     enable = [
#       "languages/typescript"
#     ];
#     disable = [
#       "terminal/nunchux"
#     ];
#   }
#
# Paths are `<domain>` or `<domain>/<member>` — the walk's ids
# (nix/lib/capabilities.nix) are the registry, so the valid paths and the
# option surface can never disagree. Semantics:
#
#   - an `enable` row pins a path ON; a `disable` row pins it OFF;
#   - defaults fill everything unpinned (core domains default on, the
#     language members default off — the enable options'
#     declarations in nix/modules/workstation-options.nix);
#   - a member implies its domain: selecting `languages/go` sets both
#     enables (the domain shell rides the selection), so a member is never
#     left selected under a domain the file disables — that combination is
#     refused at read time;
#   - `foundation` is baseline: always on, unselectable, refused in both
#     lists;
#   - `types.bool` definitions merge as a logical OR, so the translation is
#     one conflict-free mkMerge — and an `enable` row outranks a stale
#     `disable` row for the same path (the shim keeps them disjoint;
#     a hand edit that does not resolves to on, loudly and by construction).
#
# Every consumer (the report fold, both legs, the e2e personas) reads the
# pins through this library, so validation happens at every eval that could
# deploy a selection — a hand-broken file fails loudly with the fix named,
# never silently deploys.
{
  lib,
  # the flake tree (modules/ resolves against it — the walk is the registry)
  treeRoot,
}:
let
  capabilityWalk = import ./capabilities.nix {
    inherit lib;
    inherit treeRoot;
  };

  # the selectable universe, derived from the walk: a DOMAIN path (the head
  # of a capability id) or a MEMBER path (a full two-segment id)
  domains = lib.unique (map (id: builtins.head (lib.splitString "/" id)) capabilityWalk.ids);
  members = builtins.filter (id: lib.length (lib.splitString "/" id) == 2) capabilityWalk.ids;
  baselineDomains = [ "foundation" ];

  pathKind =
    path:
    if builtins.elem path baselineDomains then
      "baseline"
    else if builtins.elem path domains then
      "domain"
    else if builtins.elem path members then
      "member"
    else
      null;

  # `<domain>` or `<domain>/<member>`, `/`-separated, [A-Za-z0-9_-] only —
  # validated before any consumer touches the path (no shell or nix
  # injection surface reaches an eval, an attrpath, or a file write)
  grammarOk = path: builtins.match "[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)?" path != null;

  # the pins file -> the two lists, validated. Tolerant of an absent file
  # (the pre-init tree) and of the canonical empty form (`enable` only);
  # strict about everything else — a foreign attribute, a malformed path,
  # an unknown path, a baseline pin, or a domain-disabled-under-a-selected-
  # member contradiction all throw naming the file and the fix.
  readPins =
    file:
    let
      raw = if builtins.pathExists file then import file else { };
      pins = {
        enable = raw.enable or [ ];
        disable = raw.disable or [ ];
      };
      foreign = builtins.filter (
        name:
        !builtins.elem name [
          "enable"
          "disable"
        ]
      ) (builtins.attrNames raw);
      all = pins.enable ++ pins.disable;
      malformed = builtins.filter (path: !grammarOk path) all;
      unknown = builtins.filter (path: pathKind path == null) all;
      baseline = builtins.filter (path: pathKind path == "baseline") all;
      contradictions = builtins.filter (
        path:
        pathKind path == "domain" && builtins.any (member: lib.hasPrefix "${path}/" member) pins.enable
      ) pins.disable;
    in
    assert
      foreign == [ ]
      || throw "workstation-selections: ${toString file} carries unexpected attribute(s) (${lib.concatStringsSep ", " foreign}) — the file holds only the enable and disable lists";
    assert
      malformed == [ ]
      || throw "workstation-selections: ${toString file} carries malformed path(s) (${lib.concatStringsSep ", " malformed}) — the grammar is <domain> or <domain>/<member>, [A-Za-z0-9_-] only";
    assert
      unknown == [ ]
      || throw "workstation-selections: ${toString file} names unknown path(s) (${lib.concatStringsSep ", " unknown}) — workstation selected lists the valid paths";
    assert
      baseline == [ ]
      || throw "workstation-selections: ${toString file} pins baseline path(s) (${lib.concatStringsSep ", " baseline}) — the baseline is always on";
    assert
      contradictions == [ ]
      || throw "workstation-selections: ${toString file} disables ${lib.concatStringsSep ", " contradictions} while selecting members under them — a member implies its domain, so remove the member selection first";
    pins;

  # the pins file -> one module: enable rows set their enable (a member
  # implies its domain — both paths are set); disable rows set false,
  # member-scoped (disabling a member never touches its domain — disabling
  # the domain is its own row and takes the members with it through the
  # domain/member AND gate).
  translationModule =
    file:
    let
      pins = readPins file;
      setEnable =
        value: path:
        let
          parts = lib.splitString "/" path;
        in
        lib.mkMerge (
          [ (lib.setAttrByPath ([ "workstation" ] ++ parts ++ [ "enable" ]) value) ]
          ++ lib.optionals (value && lib.length parts == 2) [
            (lib.setAttrByPath [
              "workstation"
              (builtins.head parts)
              "enable"
            ] value)
          ]
        );
    in
    {
      config = lib.mkMerge (map (setEnable true) pins.enable ++ map (setEnable false) pins.disable);
    };
in
{
  inherit
    capabilityWalk
    domains
    members
    baselineDomains
    pathKind
    grammarOk
    readPins
    translationModule
    ;
}
