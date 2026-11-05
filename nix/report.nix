# The read verbs' source: one evaluation of the machine's home plane.
# Each declaration is attributed to the capability whose module defines it
# (options.<x>.definitionsWithLocations); the capability paths and their
# defaults come from the option tree.
{
  lib,
  eval,
  root,
  settings,
}:
let
  inherit (eval) config options;

  modulesRoot = "${toString root}/modules/";

  idOf =
    file:
    let
      f = toString file;
    in
    if lib.hasPrefix modulesRoot f then
      lib.concatStringsSep "/" (lib.init (lib.splitString "/" (lib.removePrefix modulesRoot f)))
    else
      null;

  live = v: !(builtins.isAttrs v && (v._type or "") == "if" && !v.condition);

  defsBy =
    opt:
    builtins.filter (d: d.id != null) (
      map (d: {
        id = idOf d.file;
        inherit (d) value;
      }) opt.definitionsWithLocations
    );

  fileDefs =
    (map (d: d // { value = lib.filterAttrs (_: live) d.value; }) (defsBy options.home.file))
    ++ map (
      d:
      d
      // {
        value = lib.mapAttrs' (k: lib.nameValuePair ".config/${k}") (lib.filterAttrs (_: live) d.value);
      }
    ) (defsBy options.xdg.configFile);
  recursiveOf = v: builtins.isAttrs v && (v.recursive or false) == true;
  fileTargetsOf =
    id:
    lib.concatMap (d: builtins.attrNames (lib.filterAttrs (_: v: !recursiveOf v) d.value)) (
      byId id fileDefs
    );
  claimTargetsOf =
    id:
    lib.concatMap (d: builtins.attrNames (lib.filterAttrs (_: recursiveOf) d.value)) (byId id fileDefs);

  byId = id: builtins.filter (d: d.id == id);

  programsOf =
    id:
    builtins.filter (
      n:
      let
        o = options.programs.${n};
      in
      !(lib.isOption o)
      && lib.isOption (o.enable or null)
      && builtins.any (d: d.value == true) (byId id (defsBy o.enable))
    ) (builtins.attrNames options.programs);

  packagesOf =
    id:
    lib.concatMap (d: map (p: p.pname or p.name) (builtins.filter live d.value)) (
      byId id (defsBy options.home.packages)
    );

  declaredHere = opt: builtins.any (f: idOf f != null) (opt.declarations or [ ]);
  domainNames = builtins.filter (
    n:
    let
      o = options.workstation.${n};
    in
    !(lib.isOption o) && builtins.any declaredHere (lib.collect lib.isOption o)
  ) (builtins.attrNames options.workstation);

  memberNames =
    d:
    builtins.filter (
      m:
      let
        o = options.workstation.${d}.${m};
      in
      !(lib.isOption o) && lib.isOption (o.enable or null) && declaredHere o.enable
    ) (builtins.attrNames options.workstation.${d});

  rowsOf =
    d:
    let
      o = options.workstation.${d};
      domainOn = config.workstation.${d}.enable or true;
    in
    [
      {
        path = d;
        kind = if lib.isOption (o.enable or null) then "domain" else "baseline";
        default = if lib.isOption (o.enable or null) then o.enable.default else true;
        on = domainOn;
        note = if lib.isOption (o.enable or null) then o.enable.description else "always on";
      }
    ]
    ++ map (m: {
      path = "${d}/${m}";
      kind = "member";
      default = o.${m}.enable.default;
      on = domainOn && config.workstation.${d}.${m}.enable;
      note = o.${m}.enable.description;
    }) (memberNames d);

  rows = lib.sort (a: b: a.path < b.path) (lib.concatMap rowsOf domainNames);
  paths = map (r: r.path) rows;

  stateOf =
    r:
    if r.kind == "baseline" then
      "baseline"
    else if r.on then
      "on"
    else
      "off";

  pinsOf =
    tree:
    let
      walk =
        prefix: t:
        lib.concatLists (
          lib.mapAttrsToList (
            k: v:
            if k == "enable" && builtins.isBool v then
              [
                {
                  path = lib.concatStringsSep "/" prefix;
                  value = v;
                }
              ]
            else if builtins.isAttrs v then
              walk (prefix ++ [ k ]) v
            else
              [ ]
          ) t
        );
    in
    walk [ ] tree;
  pinRows = builtins.filter (p: builtins.elem p.path paths) (pinsOf (settings.workstation or { }));
  pins = {
    enable = map (p: p.path) (builtins.filter (p: p.value) pinRows);
    disable = map (p: p.path) (builtins.filter (p: !p.value) pinRows);
  };

  capabilities = builtins.listToAttrs (
    map (
      r:
      lib.nameValuePair r.path {
        id = r.path;
        state = stateOf r;
        fileTargets = fileTargetsOf r.path;
        claimTargets = claimTargetsOf r.path;
        packages = packagesOf r.path;
        programs = programsOf r.path;
      }
    ) rows
  );

  allOf = f: lib.sort (a: b: a < b) (lib.unique (lib.concatMap f paths));
  fileTargetNames = allOf fileTargetsOf;
  claimTargets = allOf claimTargetsOf;
  programs = allOf programsOf;

  planBody = {
    inherit
      fileTargetNames
      claimTargets
      programs
      pins
      ;
  };
in
{
  status = {
    capabilityOrder = paths;
    counts = {
      capabilities = builtins.length paths;
      enabled = builtins.length (builtins.filter (r: stateOf r != "off") rows);
      fileTargets = builtins.length fileTargetNames;
      claimTargets = builtins.length claimTargets;
      programs = builtins.length programs;
    };
  };

  plan = planBody // {
    digest = builtins.hashString "sha256" (builtins.toJSON planBody);
  };

  inherit capabilities;

  selectable = builtins.listToAttrs (
    map (
      r:
      lib.nameValuePair r.path {
        inherit (r) kind default;
        baseline = r.kind == "baseline";
      }
    ) rows
  );

  selections = {
    inherit pins;
    rows = builtins.listToAttrs (
      map (
        r:
        lib.nameValuePair r.path {
          state = stateOf r;
          inherit (r) note;
        }
      ) rows
    );
  };
}
