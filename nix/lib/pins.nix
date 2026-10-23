# The pin machinery: the manifest walker's download/git lanes re-landed as
# native derivations (docs/absorption.md, "The mapping"). Modules declare
# WHAT is pinned; this library owns HOW a pin becomes a store path:
#
#   tool       — a fetchurl-backed tree from the versions.json inventory
#                (workstation/versions.json stays the interim pin
#                inventory: nix reads it with builtins.fromJSON; no pin is
#                duplicated into module literals)
#   fetchGitPin — a fetchGit-pinned checkout (url + rev from the inventory)
#   compose    — the under-dir-claim composition (immutable store cannot
#                host a file inside a dir symlink, so children overlay into
#                one derived tree — the walker's claim composition)
#
# The probe honesty gate is a BUILD-TIME assertion: a wrong pin fails the
# build, not a host verify. Two shapes, straight from the download
# contract — a tree proves it is the pinned tool through exactly one:
#   exec   { argv, output }  — argv[0] is a relative member of the staged
#           tree; the first output line must equal the template with {V}
#           substituted by the pinned version
#   member { member, sha256 } — the staged member's sha256 must match
#
# Archive layouts (the download contract's closed vocabulary):
#   release (the default) — the archive carries exactly one root; a root
#     DIRECTORY extracts with one component stripped; a lone root FILE is
#     the installed tree (single-binary release archives); multi-root is a
#     loud failure — merging unrelated top-level members into one target is
#     never a silent act
#   flat — the members live at the archive's top level with no owning root
{
  lib,
  pkgs,
  # the pin inventory — override only in tests; every consumer reads the
  # same bytes
  pinsJson ? builtins.fromJSON (builtins.readFile ../../workstation/versions.json),
}:
let
  # platform vocabulary: the same tag set the inventory keys on
  platform =
    if pkgs.stdenv.hostPlatform.isx86_64 && pkgs.stdenv.hostPlatform.isLinux then
      "linux_x86_64"
    else if pkgs.stdenv.hostPlatform.isAarch64 && pkgs.stdenv.hostPlatform.isDarwin then
      "darwin_arm64"
    else
      throw "workstation-pins: no platform mapping for system '${pkgs.system}' (the inventory knows linux_x86_64 and darwin_arm64)";

  hex64 = h: builtins.match "[0-9a-f]{64}" h != null;

  # the {V} substitution the inventory URL templates carry
  withVersion = version: url:
    if version != null then builtins.replaceStrings [ "{V}" ] [ version ] url else url;

  # one pinned tool tree from the inventory: the version/url/sha256 rows are
  # "<name>", "<name>_<platform>_url", "<name>_<platform>_sha256"; the
  # archive/layout/probe discipline is the OWNING MODULE's declaration (the
  # download contract's data, moved from the manifests into the modules).
  tool = name: meta@{
    archive ? "none",
    layout ? "release",
    probe ? null,
    version ? null,
    url ? null,
    sha256 ? null,
  }:
    let
      v = if meta.version or null != null then meta.version else pinsJson.${name}
        or (throw "workstation-pins: no version pin '${name}' in the inventory (declare version explicitly for tools whose pin lives elsewhere, e.g. the node payload's .node-version)");
      u = if meta.url or null != null then meta.url else withVersion v
        (pinsJson."${name}_${platform}_url"
          or (throw "workstation-pins: no ${platform} url pin '${name}_${platform}_url' in the inventory"));
      s = if meta.sha256 or null != null then meta.sha256 else pinsJson."${name}_${platform}_sha256"
        or (throw "workstation-pins: no ${platform} sha256 pin '${name}_${platform}_sha256' in the inventory");
    in
    assert hex64 s
      || throw "workstation-pins: pin sha256 of '${name}' is not a 64-hex digest (the download contract's eval-time gate)";
    fetchPin {
      inherit name archive layout probe;
      version = v;
      url = u;
      sha256 = s;
    };

  # the derivation: fetch, unpack, normalize the layout, probe-gate
  fetchPin = {
    name,
    version,
    url,
    sha256,
    archive ? "none",
    layout ? "release",
    probe ? null,
  }:
    assert lib.elem archive [ "none" "tar.gz" "tar.xz" "zip" ]
      || throw "workstation-pins: unsupported archive '${archive}' for '${name}' (the contract knows none, tar.gz, tar.xz, zip)";
    assert lib.elem layout [ "release" "flat" ]
      || throw "workstation-pins: unsupported layout '${layout}' for '${name}' (the contract knows release, flat)";
    let
      # the exec probe runs the staged binary on the builder; a dynamic
      # glibc binary cannot reach /lib64 inside the sandbox, so the gate
      # retries through the builder's own loader (bytes never mutated)
      loader = if pkgs.stdenv.isLinux then
        "${pkgs.stdenv.cc.libc}/lib/ld-linux-x86-64.so.2" else "";
      probeCheck =
        if probe == null then ""
        else if probe ? argv then ''
          expected=${lib.escapeShellArg (builtins.replaceStrings [ "{V}" ] [ version ] probe.output)}
          probe_out=$("$@" 2>/dev/null || true)
          first=$(printf '%s\n' "$probe_out" | head -n 1)
          if [ -z "$first" ] && [ -n "${loader}" ]; then
            probe_out=$(${loader} "$@" 2>/dev/null || true)
            first=$(printf '%s\n' "$probe_out" | head -n 1)
          fi
          if [ "$first" != "$expected" ]; then
            echo "ws-pin ${name}: exec probe failed — wanted '$expected', got '$first'" >&2
            exit 1
          fi
        ''
        else ''
          got=$(sha256sum "$out/${probe.member}" | cut -d' ' -f1)
          if [ "$got" != "${probe.sha256}" ]; then
            echo "ws-pin ${name}: member probe failed — ${probe.member} sha256 $got != ${probe.sha256}" >&2
            exit 1
          fi
        '';
      probeArgs =
        if probe == null || !(probe ? argv) then ""
        else lib.concatMapStrings (a: " ${lib.escapeShellArg a}") probe.argv;
    in
    assert probe != null -> ((probe ? argv) != (probe ? member))
      || throw "workstation-pins: probe of '${name}' must declare exactly one shape (argv+output, or member+sha256)";
    pkgs.runCommand "ws-pin-${name}"
      {
        src = pkgs.fetchurl { inherit url sha256; };
        nativeBuildInputs = lib.optionals (archive == "zip") [ pkgs.unzip ];
        passthru.pinVersion = version;
      }
      (
        if archive == "none" then
          # archive-less pin: the fetched bytes ARE the binary; the tree
          # exposes it at bin/<name> (consumers link the store path directly)
          ''
            set -euo pipefail
            install -Dm755 "$src" "$out/bin/${name}"
          ''
        else ''
          set -euo pipefail
          mkdir -p staging "$out"
          case "$archive" in
            tar.gz) tar -xf "$src" -C staging ;;
            tar.xz) tar -xf "$src" -C staging ;;
            zip) unzip -q "$src" -d staging ;;
          esac
          ${
            if layout == "release" then
              ''
                entries=$(ls -A staging)
                count=$(printf '%s\n' "$entries" | wc -l)
                if [ "$count" -ne 1 ]; then
                  echo "ws-pin ${name}: multi-root release archive ($count roots) — a loud failure, never a silent merge" >&2
                  exit 1
                fi
                if [ -d "staging/$entries" ]; then
                  # the release-archive layout: the single root strips
                  mv "staging/$entries" normalized
                else
                  # a lone root FILE is the installed tree (single-binary
                  # release archives); members address as <root>/<file>
                  mkdir normalized
                  mv "staging/$entries" "normalized/$entries"
                fi
              ''
            else
              ''mv staging normalized'' # flat: the members are the tree
          }
          cp -a normalized/. "$out/"
          chmod -R u+w "$out"
          (cd "$out" && set -- ${probeArgs} && ${probeCheck})
        ''
      );

  # a pinned git checkout (fetchGit, exact rev — the six plugin checkouts).
  # The rev/url come from the inventory ("<name>_git_commit"/"<name>_git_url")
  # unless the caller pins them explicitly.
  fetchGitPin = name: meta@{ url ? null, rev ? null, ... }:
    let
      r = if meta.rev or null != null then meta.rev else pinsJson."${name}_git_commit"
        or (throw "workstation-pins: no git pin '${name}_git_commit' in the inventory");
      u = if meta.url or null != null then meta.url else pinsJson."${name}_git_url"
        or (throw "workstation-pins: no git pin '${name}_git_url' in the inventory");
    in
    builtins.fetchGit { url = u; rev = r; };

  # the under-dir-claim composition: children (files or whole trees)
  # overlay INTO the base tree — immutable store cannot host a file inside
  # a dir symlink, so the composed tree is one derivation
  compose = base: children:
    if children == [ ] then base
    else
      pkgs.runCommand "ws-composed-${base.name or "tree"}"
        {
          passthru.children = builtins.attrNames (builtins.listToAttrs (map (c: { name = c.path; value = true; }) children));
        }
        ''
          set -euo pipefail
          mkdir -p "$out"
          cp -a ${base}/. "$out/"
          chmod -R u+w "$out"
          ${lib.concatStrings (map
            (c: ''
              mkdir -p "$out/$(dirname "${c.path}")"
              if [ -d "${c.source}" ]; then
                mkdir -p "$out/${c.path}"
                cp -a "${c.source}"/. "$out/${c.path}"/
              else
                cp -a "${c.source}" "$out/${c.path}"
              fi
            '')
            children)}
        '';
in
{
  inherit platform tool fetchGitPin compose pinsJson;
  # raw inventory access for consumers that read a pin row directly (the
  # hermes checkout ensure bakes url+rev into an activation script)
  inventory = pinsJson;
}
