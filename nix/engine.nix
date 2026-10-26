# The workstation engine as ONE nix mixRelease — the build gate's
# known-good answer (t_42783d30), landed verbatim (t_f8b0684a).
#
# Shape: beam28 (Erlang/OTP 28.1 + Elixir 1.18.4 from nixpkgs 25.05 — the
# host mise pin runs 1.18.5/OTP 28.5; match-vs-skew is an open substrate
# decision). The mdex_native NIF needs NO source change: today's build
# shape is the rustler_precompiled DOWNLOAD path (mdex_native ships
# `rustler` as an OPTIONAL dep, so the lock has no rustler). In the nix
# sandbox there is no network at compile time (HEX_OFFLINE=1), so the
# exact artifact is vendored via RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH
# (read VERBATIM, flat). Integrity stays enforced — with NO checksum
# map: on a global-cache hit rustler_precompiled TRUSTS the artifact and
# skips its own checksum verification entirely (gate-proven on
# t_ec445584 — a checksum exs pinned to a lying digest still built and
# ran, so the old checksum-MDExNative.Native.exs was decorative and is
# gone). Enforcement is two real layers: nix's fetchurl sha256 pin
# (nifHex) and the explicit preConfigure digest check against
# nifSha256Pinned below, which fails the build before mix deps.compile.
# The aarch64-darwin target EVALS but its NIF vendoring is still
# x86_64-linux-gated (per-target artifacts remain an open gap).
{
  lib,
  stdenv,
  runCommand,
  fetchurl,
  beamPackages,
  src,
  # the declared-state report JSON (flake.evalReport at this snapshot) —
  # baked into the release so the read verbs serve the same flake
  # snapshot that built it (nix/report.nix is the fold). null on build
  # systems the fold does not eval (the darwin leg; reads then fail closed).
  report ? null,
}:

let
  # --- mdex_native 0.2.10 precompiled NIF (x86_64-linux-gnu, nif 2.15) ---
  nifFile = "libmdex_native_nif-v0.2.10-nif-2.15-x86_64-unknown-linux-gnu.so.tar.gz";
  nifHex = "55c9b7abfbb6ddc8971fcd438fb792eb87aebaede8056591b6373130827ee448";
  # The integrity pin. A SEPARATE literal from the fetchurl pin ON
  # PURPOSE: a single-point edit of either value — or a swapped URL with
  # only the fetch pin updated — fails the build in preConfigure instead
  # of passing silently. Update BOTH digests together on a deliberate
  # artifact bump.
  nifSha256Pinned = "55c9b7abfbb6ddc8971fcd438fb792eb87aebaede8056591b6373130827ee448";
  nifArtifact = fetchurl {
    url = "https://github.com/leandrocp/mdex_native/releases/download/v0.2.10/${nifFile}";
    sha256 = nifHex;
  };
  # cache_dir("precompiled_nifs") with the global env var set returns the
  # path VERBATIM (no subdir join) — hence the flat layout.
  nifCache = runCommand "mdex-native-nif-cache" { } ''
    mkdir -p $out
    cp ${nifArtifact} $out/${nifFile}
  '';
  isX86_64Linux = stdenv.hostPlatform.isx86_64 && stdenv.hostPlatform.isLinux;

  # All-hex lock (no git deps) — fetchMixDeps covers it; the fixed-output
  # hash is over the deps tree, which depends only on mix.lock bytes.
  mixDeps = beamPackages.fetchMixDeps {
    pname = "workstation";
    version = "0.1.0";
    inherit src;
    sha256 = "sha256-Yj2Hxh18XKM73pii+ll0xe7ZtqLYisNwCIDBe/+HAsM=";
  };
in
beamPackages.mixRelease {
  pname = "workstation";
  version = "0.1.0";
  inherit src;
  mixFodDeps = mixDeps;
  # The mix-generated bin/workstation_ctl reads releases/COOKIE at boot;
  # the default (removeCookie = true) deletes it and the release control
  # surface then dies on `cat: releases/COOKIE`. The control verbs
  # (`workstation start`/`stop`, the dist node surface) genuinely use
  # distribution, so the cookie stays (it is baked into the derivation by
  # `mix release`).
  removeCookie = false;

  # Integrity gate before `mix deps.compile` (the mdex_native compile
  # happens in configurePhase): rustler_precompiled copies the artifact
  # out of the global cache WITHOUT any checksum check on a cache hit,
  # so the vendored bytes are verified here — a mismatch fails the build
  # before the NIF can reach the release (tamper probe: t_ec445584).
  preConfigure = lib.optionalString isX86_64Linux ''
    nifArtifactPath="${nifCache}/${nifFile}"
    actualSha256="$(sha256sum "$nifArtifactPath" | cut -d' ' -f1)"
    if [ "$actualSha256" != "${nifSha256Pinned}" ]; then
      echo "integrity: vendored mdex_native NIF digest mismatch — refusing to build" >&2
      echo "  file:   $nifArtifactPath" >&2
      echo "  pinned: ${nifSha256Pinned}" >&2
      echo "  actual: $actualSha256" >&2
      exit 1
    fi
  '';

  env = lib.optionalAttrs isX86_64Linux {
    RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH = "${nifCache}";
  };

  # NOTE: the default postFixup strips ${erlang} references and wraps
  # $out/bin with a PATH of coreutils/gnused/gnugrep/gawk. Kept as-is —
  # the build gate's consumer smoke passed against this exact shape.

  # The declared-state report bakes at share/workstation/eval-report.json
  # (Workstation.Core.Report's release path): release and declared state
  # ship from one flake snapshot, so the read verbs are coherent by
  # construction.
  postInstall = lib.optionalString (report != null) ''
    install -Dm644 ${
      builtins.toFile "eval-report.json" report
    } $out/share/workstation/eval-report.json
  '';
}
