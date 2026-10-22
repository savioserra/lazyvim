# The nix walker: consumes the package tree as DATA — nix is a renderer,
# never a re-authoring (program root law). Manifest.json bytes are the one
# source; every lane below is derived, and every envelope is accounted:
#   rendered lanes: file, symlink, fragment, tool-binlink, download-tree,
#                   git-checkout, nvim-profile, nvim-bin-nixpkgs
#   refused lanes:  template/private/exact, modify/remove (engine contract
#                   until the nix write plane retires it), copy + .hermes git
#                   (hot-home law: HM must never manage ~/.hermes),
#                   chezmoi-data (engine runtime data), mise (deleted:
#                   toolchains come from nixpkgs), platform-missing downloads
# A refused envelope that a render lane is ever ASKED to render throws a
# clear eval error naming the kind — refusal is never silent.
#
# Store-tree law: the store tree of a download IS the staged install tree
# the symlinks were authored against (release/flat archives are replicated
# verbatim; archive=none synthesizes bin/<name>). Immutable store means
# overlapping targets (node inside nvm, a payload file inside a git
# checkout) compose into one derived tree instead of colliding.
{
  lib,
  pkgs,
  treeRoot,
  platform ? null,
  # REQUIRED — no default may bake an identity (t_40cf3088). Callers pass
  # the host's home.homeDirectory; hosts/<host>/default.nix is the single
  # identity surface. Omitting it fails eval here instead of silently
  # rendering a stranger's home paths.
  homeDir,
}:
let
  platform' =
    if platform != null then
      platform
    else if pkgs.stdenv.hostPlatform.isx86_64 && pkgs.stdenv.hostPlatform.isLinux then
      "linux_x86_64"
    else if pkgs.stdenv.hostPlatform.isAarch64 && pkgs.stdenv.hostPlatform.isDarwin then
      "darwin_arm64"
    else
      throw "workstation-nix: no manifest asset platform mapping for system '${pkgs.system}' (contract knows linux_x86_64 and darwin_arm64)";

  # Recursive manifest discovery — mirrors the engine's discovery law
  # (deterministic, no registration list). Package roots sit at variable
  # depth: packages/fonts/manifest.json AND packages/agent/herdr/manifest.json
  # are both roots.
  wsRoot = treeRoot + "/workstation";
  walk =
    rel:
    let
      dir = wsRoot + "/${rel}";
      entries = builtins.readDir dir;
      regulars = lib.filterAttrs (_: t: t == "regular") entries;
      subdirs = lib.filterAttrs (_: t: t == "directory") entries;
      here = if regulars ? "manifest.json" then
        [{
          manifest = builtins.fromJSON (builtins.readFile (dir + "/manifest.json"));
          inherit rel;
        }] else
        [ ];
    in
    here ++ lib.concatLists (lib.mapAttrsToList (n: _: walk "${rel}/${n}") subdirs);

  discovered = walk "packages";
  manifests = map (e: e.manifest) discovered;

  ownerOfEnvelope = e:
    (lib.findFirst (m: lib.any (x: x == e) (m.contributes or [ ]))
      (throw "workstation-nix: envelope owner not found") manifests).id;
  rootOf = id:
    (lib.findFirst (e: e.manifest.id or "" == id)
      (throw "workstation-nix: no manifest for package '${id}'") discovered).rel;

  envelopes = lib.concatMap (m: m.contributes or [ ]) manifests;

  identOf = e:
    let
      s = e.spec;
      primary =
        if (s.entry or null) != null then s.entry.id
        else if (s.fragment or null) != null then "${s.fragment.id}@${s.target}"
        else if (s.target or null) != null then s.target
        else if (s.targets or null) != null then s.targets.${platform'}
        else null;
      fallback = s.asset or s.commit
        or (if (s.content or null) != null then "theme-data" else "anon");
    in "${ownerOfEnvelope e}#${e.provider}:${if primary != null then primary else fallback}";

  # --- refusal registry -----------------------------------------------------
  # Every lane here is a decision the program has NOT made yet; the reason
  # strings are load-bearing (the eval golden pins them verbatim).
  #
  # Platform condition: a download envelope whose manifest pins no asset
  # for THIS platform is refused (never a hard error — the eval golden is
  # the x86_64-linux report, whose downloads all pin linux_x86_64; on
  # darwin the refused tool's nixpkgs equivalent must join the host's nix
  # set). The refusal PROPAGATES to the opt-tree link envelope that would
  # dangle without its download (a .local/bin link to ../opt/<tool> whose
  # tool never materializes would shadow the nix-set binary).
  refusedToolNames = lib.unique (lib.concatMap (e:
    if e.provider == "download" && refuseReason e != null then
      [ lib.last (lib.splitString "/" (e.spec.target
        or ((e.spec.targets or { }).${platform'} or (identOf e)))) ]
    else [ ]) envelopes);

  refuseReason = e:
    if e.provider == "download" then
      (if (e.spec.assets or { }) ? ${platform'}
        then null
        else "no ${platform'} asset: the nix set must own ${e.spec.target
          or (identOf e)}")
    else if e.provider == "shell" || e.provider == "nvim-profile" then null
    else if e.provider == "git" then
      (if lib.hasPrefix ".hermes/" e.spec.target then
        "engine-owned hot-home: HM must never manage ~/.hermes" else null)
    else if e.provider == "copy" then
      "engine-owned hot-home: HM must never manage ~/.hermes"
    else if e.provider == "chezmoi-data" then
      "engine-owned runtime data"
    else if e.provider == "mise" then
      "deleted in nix land: toolchains come from nixpkgs"
    else if e.provider == "chezmoi" then
      let
        s = e.spec;
        k = s.kind or "file";
        parts = lib.splitString "/" (s.to or "");
        toolName = lib.elemAt parts 2;
      in
      if k == "symlink" && lib.take 2 parts == [ ".." "opt" ]
        && lib.elem toolName refusedToolNames then
        "tool '${toolName}' has no ${platform'} download: the link would dangle — the nix set owns it"
      else if k == "file" || k == "symlink" then
        (if s.template or false then
          "backend-rendered template: engine contract until the nix write plane retires it"
        else if s.private or false then
          "backend-rendered private: engine contract until the nix write plane retires it"
        else if s.exact or false then
          "backend-rendered exact: engine contract until the nix write plane retires it"
        else null)
      else "mutable kind '${k}': engine contract until the nix write plane retires it"
    else throw "workstation-nix: envelope provider '${e.provider}' is not part of the known contract";

  # A render lane asked to touch a refused envelope must die loudly.
  assertRenderable = e:
    if refuseReason e == null then true
    else throw "workstation-nix: refusing to render envelope '${identOf e}' — ${refuseReason e}";

  # --- ordering: requires-graph topo order (closure length, then id) --------
  byId = builtins.listToAttrs (map (m: { name = m.id; value = m; }) manifests);
  closure = m:
    lib.unique (lib.flatten (map
      (r: if byId ? ${r} then [ r ] ++ closure byId.${r} else [ ])
      (m.requires or [ ])));
  topo = lib.sort (a: b:
    lib.lessThan [ (builtins.length (closure a)) a.id ]
    [ (builtins.length (closure b)) b.id ]) manifests;
  topoIndex = m:
    lib.lists.findFirstIndex (x: x.id == m.id) 999 topo;

  # --- downloads: manifest pins -> derivations ------------------------------
  hex64 = h: builtins.match "[0-9a-f]{64}" h != null;
  assetOf = e:
    (e.spec.assets or { }).${platform'}
      or (throw "workstation-nix: download envelope '${identOf e}' has no ${platform'} asset");
  targetOf = e:
    e.spec.target or ((e.spec.targets or { }).${platform'}
      or (throw "workstation-nix: download envelope '${identOf e}' has no ${platform'} target"));

  toolRecs = lib.concatMap (e:
    if e.provider != "download" then [ ] else
    let asset = assetOf e;
    in [{
      id = identOf e;
      name = lib.last (lib.splitString "/" (targetOf e));
      target = targetOf e;
      archive = e.spec.archive or "none";
      url = asset.url;
      sha256 = asset.sha256;
    }]) envelopes;

  toolDrv = t:
    assert if hex64 t.sha256 then true
    else throw "workstation-nix: pin sha256 of '${t.id}' is not a 64-hex digest (download contract gate, moved to eval time)";
    pkgs.runCommand "ws-tool-${t.name}"
      {
        src = pkgs.fetchurl { inherit (t) url sha256; };
        archive = t.archive;
        nativeBuildInputs = lib.optionals (t.archive == "zip") [ pkgs.unzip ];
      }
      ''
        set -euo pipefail
        mkdir -p staging "$out"
        case "$archive" in
          none)
            # archive-less pin: the fetched bytes ARE the binary
            install -Dm755 "$src" "$out/bin/${t.name}"; exit 0 ;;
          tar.gz|tar.xz) tar -xf "$src" -C staging ;;
          zip) unzip -q "$src" -d staging ;;
          *) echo "ws-tool: unsupported archive $archive" >&2; exit 1 ;;
        esac
        # release and flat layouts replicate the staged tree EXACTLY (the
        # symlinks in the tree are authored against this shape — the store
        # tree is the install truth; no lone-root special-casing)
        cp -a staging/. "$out/"
        chmod -R u+w "$out"
      '';

  toolsById = builtins.listToAttrs
    (map (t: { name = t.name; value = toolDrv t; }) toolRecs);

  # tool names whose binaries the tree reaches through ../opt/<name> links —
  # those opt roots die (the store path IS the install truth); every other
  # download materializes at its manifest target
  binLinkNames = lib.unique (lib.concatMap (e:
    if e.provider == "chezmoi" && (e.spec.kind or "file") == "symlink" then
      let
        parts = lib.splitString "/" e.spec.to;
        toolName = lib.elemAt parts 2;
      in if lib.take 2 parts == [ ".." "opt" ] && toolsById ? ${toolName}
      then [ toolName ] else [ ]
    else [ ]) envelopes);

  isNvimLink = e:
    e.provider == "chezmoi" && (e.spec.kind or "file") == "symlink"
    && e.spec.target == ".local/bin/nvim";

  # link recipe: chezmoi symlink envelopes come in two shapes —
  #   ../opt/<tool>/<rest>  -> the tool derivation's tree (rest preserved:
  #                            the drv replicates the staged tree exactly)
  #   ../../.tmux.conf      -> intra-home: absolute home-relative string; the
  #                            module wraps it in mkOutOfStoreSymlink
  normalizeLink = target: to:
    let
      dirComps = lib.init (lib.splitString "/" target);
      step = acc: c:
        if c == ".." then lib.init acc else acc ++ [ c ];
    in lib.concatStringsSep "/" (lib.foldl step dirComps (lib.splitString "/" to));
  linkSource = target: spec:
    let
      parts = lib.splitString "/" spec.to;
      toolName = lib.elemAt parts 2;
    in
    if lib.take 2 parts == [ ".." "opt" ] && toolsById ? ${toolName} then
      "${toolsById.${toolName}}/" + lib.concatStringsSep "/" (lib.drop 3 parts)
    # opt-tree entries that are NOT download pins (agent launcher, the nvim
    # bootstrap pin replaced by the nvim-profile lane) stay explicit,
    # home-relative links — never guessed
    else "${homeDir}/${normalizeLink target spec.to}";

  # plain file/symlink targets render to home.file; refused shapes go through
  # assertRenderable so any future lane touching them dies loudly.
  plainChezmoi = lib.filter (e:
    e.provider == "chezmoi"
    && ((e.spec.kind or "file") == "file" || (e.spec.kind or "file") == "symlink")
    && !(e.spec.template or false) && !(e.spec.private or false)
    && !(e.spec.exact or false)) envelopes;
  backendRendered = lib.filter (e:
    e.provider == "chezmoi"
    && (!(lib.elem (e.spec.kind or "file") [ "file" "symlink" ])
      || (e.spec.template or false) || (e.spec.private or false)
      || (e.spec.exact or false))) envelopes;
  mutableKinds = lib.filter (e:
    e.provider == "chezmoi"
    && lib.elem (e.spec.kind or "file") [ "modify" "remove" "directory" ])
    envelopes;

  # a target that sits inside a dir claim (git checkout / download tree)
  # is composed into that tree — immutable store cannot host a file inside
  # a dir symlink, so the child never renders standalone. Only dir claims
  # can be parents, so this deliberately scans (downloadClaims ++
  # gitClaims), NOT claimRecs (fileClaims would close a lazy cycle).
  underDirClaimTarget = t:
    lib.any (d: !d.leaf && lib.hasPrefix "${d.target}/" t)
      (downloadClaims ++ gitClaims);

  fileTargets = builtins.listToAttrs (map (e:
    assert assertRenderable e;
    let s = e.spec;
    in if (s.kind or "file") == "symlink" then {
      name = s.target;
      value.source = linkSource s.target s;
    } else {
      name = s.target;
      value.source = wsRoot + "/${rootOf (ownerOfEnvelope e)}/${s.asset}";
    })
    (lib.filter (e: !underDirClaimTarget e.spec.target) plainChezmoi));

  # --- claims: store trees that must EXIST at a home target ------------------
  # dir claims: unlinked downloads + git checkouts. leaf claims: payload
  # files and archive-less binaries. Overlaps compose (composeClaim).
  downloadClaims = map (t: {
    inherit (t) id;
    target = t.target;
    leaf = t.archive == "none";
    source = if t.archive == "none"
      then "${toolsById.${t.name}}/bin/${t.name}"
      else toolsById.${t.name};
  }) (lib.filter (t: !lib.elem t.name binLinkNames) toolRecs);

  gitClaims = map (e: {
    id = identOf e;
    target = e.spec.target;
    leaf = false;
    source = builtins.fetchGit {
      url = e.spec.url;
      rev = e.spec.commit;
    };
  }) (lib.filter (e: e.provider == "git" && refuseReason e == null) envelopes);

  fileClaims = map (e: {
    id = identOf e;
    target = e.spec.target;
    leaf = true;
    source = wsRoot + "/${rootOf (ownerOfEnvelope e)}/${e.spec.asset}";
  }) (lib.filter (e: e.provider == "chezmoi"
    && (e.spec.kind or "file") == "file" && refuseReason e == null
    && underDirClaimTarget e.spec.target) envelopes);

  claimRecs = downloadClaims ++ gitClaims ++ fileClaims;

  targetCollision = let
    targets = builtins.attrNames fileTargets ++ map (c: c.target) claimRecs;
  in if lib.length (lib.unique targets) == lib.length targets then false
  else throw "workstation-nix: two lanes claim the same home target (${
    lib.concatStringsSep ", " targets
  })";

  isStrictlyUnder = parent: child:
    child.target != parent.target
    && lib.hasPrefix "${parent.target}/" child.target;
  betweenExists = parent: child:
    lib.any (mid:
      mid != parent && mid != child && isStrictlyUnder parent mid
      && isStrictlyUnder mid child) claimRecs;
  childrenOf = parent:
    lib.filter (c:
      isStrictlyUnder parent c && !(betweenExists parent c)) claimRecs;

  composeClaim = c:
    if c.leaf then c.source
    else
      let
        kids = childrenOf c;
        overlay = k:
          let rel = lib.removePrefix "${c.target}/" k.target;
          in if k.leaf then ''
            mkdir -p "$out/$(dirname "${rel}")"
            cp -a ${k.source} "$out/${rel}"
          '' else ''
            mkdir -p "$out/${rel}"
            cp -a ${composeClaim k}/. "$out/${rel}"
          '';
      in
      if kids == [ ] then c.source
      else
        assert targetCollision == false;
        pkgs.runCommand "ws-composed-${lib.last (lib.splitString "/" c.target)}"
          { } ''
          set -euo pipefail
          mkdir -p "$out"
          cp -a ${c.source}/. "$out/"
          # the base tree came from the store read-only; children overlay
          # into it, so hand back write permission first
          chmod -R u+w "$out"
          ${lib.concatStrings (map overlay kids)}
        '';

  # only TOP-LEVEL claims materialize standalone; children of dir claims
  # live inside their parent's composed tree (composeClaim recurses)
  topLevelClaim = c:
    !(lib.any (d: d != c && !d.leaf && isStrictlyUnder d c) claimRecs);
  claimsOut = map (c: {
    inherit (c) id target;
    source = composeClaim c;
  }) (lib.filter topLevelClaim claimRecs);

  # --- shell fragments, topo-ordered per target ------------------------------
  fragments = lib.filter (e: e.provider == "shell") envelopes;
  packageOfFragment = fragId:
    (lib.findFirst (m:
      lib.any (x: x.provider == "shell" && x.spec.fragment.id == fragId)
      (m.contributes or [ ]))
      (throw "workstation-nix: fragment owner not found") manifests);
  fragmentsForTarget = target:
    map (e: e.spec.fragment) (lib.sort (a: b:
      topoIndex (packageOfFragment a.spec.fragment.id)
      < topoIndex (packageOfFragment b.spec.fragment.id))
      (builtins.filter (e: (e.spec.target or "") == target) fragments));
  fragmentOrder = map (t: {
    inherit t;
    frags = map (f: f.id) (fragmentsForTarget t);
  }) (lib.unique (map (e: e.spec.target) fragments));
  fragmentsById = builtins.listToAttrs (map (e: {
    name = e.spec.fragment.id;
    value = e.spec.fragment;
  }) fragments);

  # --- accounting: every envelope in exactly one lane ------------------------
  laneOf = e:
    let r = refuseReason e;
    in
    if r != null then { lane = "refused"; note = r; }
    else if e.provider == "download" then
      (if lib.elem (lib.last (lib.splitString "/" (targetOf e))) binLinkNames
      then { lane = "tool-binlink"; note = null; }
      else { lane = "download-tree"; note = null; })
    else if e.provider == "shell" then { lane = "fragment"; note = null; }
    else if e.provider == "git" then { lane = "git-checkout"; note = null; }
    else if e.provider == "nvim-profile" then
      { lane = "nvim-profile"; note = null; }
    else if isNvimLink e then
      { lane = "nvim-bin-nixpkgs"; note = "bootstrap pin replaced by the nixpkgs neovim (nvim-profile lane)"; }
    else if (e.spec.kind or "file") == "symlink" then
      { lane = "symlink"; note = null; }
    else { lane = "file"; note = null; };

  accountingRaw = map (e: {
    id = identOf e;
    lane = (laneOf e).lane;
    note = (laneOf e).note;
  }) envelopes;
  accounting = lib.sort (a: b: lib.lessThan a.id b.id) accountingRaw;
  accountingUnique = assert if lib.length (lib.unique (map (a: a.id) accounting))
      == lib.length envelopes then true
    else throw "workstation-nix: envelope identities are not unique — the accounting would lie";
    accounting;

  refusedCount = lib.length (lib.filter (a: a.lane == "refused") accountingUnique);

  counts = {
    packages = builtins.length manifests;
    envelopes = builtins.length envelopes;
    tools = builtins.length toolRecs;
    chezmoi = builtins.length (lib.filter (e: e.provider == "chezmoi") envelopes);
    plainFiles = builtins.length plainChezmoi;
    backendRendered = builtins.length backendRendered;
    shell = builtins.length fragments;
    git = builtins.length (lib.filter (e: e.provider == "git") envelopes);
    nvimProfile =
      builtins.length (lib.filter (e: e.provider == "nvim-profile") envelopes);
    mise = builtins.length (lib.filter (e: e.provider == "mise") envelopes);
    mutable = builtins.length mutableKinds;
    copy = builtins.length (lib.filter (e: e.provider == "copy") envelopes);
    chezmoiData =
      builtins.length (lib.filter (e: e.provider == "chezmoi-data") envelopes);
    rendered = builtins.length envelopes - refusedCount;
    refused = refusedCount;
  };
  fileTargetNames = builtins.attrNames fileTargets;
  claimTargets = map (c: c.target) claimsOut;
  packageOrder = map (m: m.id) topo;
in
assert targetCollision == false;
{
  inherit manifests discovered topo envelopes toolsById fileTargets claimsOut
    fragmentsById fragmentOrder accounting counts fileTargetNames claimTargets
    packageOrder;
  report = {
    inherit counts fileTargetNames claimTargets packageOrder fragmentOrder
      accounting;
  };
}
