# The workstation engine as ONE nix mixRelease — P0's known-good answer
# (t_42783d30), landed verbatim per the P1 card.
#
# Shape: beam28 (Erlang/OTP 28.1 + Elixir 1.18.4 from nixpkgs 25.05 — the
# host mise pin runs 1.18.5/OTP 28.5; match-vs-skew is a P2+ substrate
# decision). The mdex_native NIF needs NO source change: today's build
# shape is the rustler_precompiled DOWNLOAD path (mdex_native ships
# `rustler` as an OPTIONAL dep, so the lock has no rustler). In the nix
# sandbox there is no network at compile time (HEX_OFFLINE=1), so the
# exact artifact is vendored via RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH
# (read VERBATIM, flat) plus the checksum map the compiler expects in the
# dep's cwd. Integrity stays enforced: the checksum exs pins sha256 of
# the artifact and rustler_precompiled verifies the tarball against it.
# The aarch64-darwin target EVALS but its NIF vendoring is still
# x86_64-linux-gated (per-target artifacts: named P0 gap).
{
  lib,
  stdenv,
  runCommand,
  fetchurl,
  writeText,
  beamPackages,
  src,
}:

let
  # --- mdex_native 0.2.10 precompiled NIF (x86_64-linux-gnu, nif 2.15) ---
  nifFile = "libmdex_native_nif-v0.2.10-nif-2.15-x86_64-unknown-linux-gnu.so.tar.gz";
  nifHex = "55c9b7abfbb6ddc8971fcd438fb792eb87aebaede8056591b6373130827ee448";
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
  # The checksum map rustler_precompiled reads from File.cwd!() during
  # compile of MDExNative.Native (i.e. $MIX_DEPS_PATH/mdex_native).
  checksumExs = writeText "checksum-MDExNative.Native.exs" ''
    %{
      "${nifFile}" => "sha256:${nifHex}",
    }
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
  # the default (removeCookie = true) deletes it and the daemon then dies
  # on `cat: releases/COOKIE`. The daemon genuinely uses distribution, so
  # the cookie stays (it is baked into the derivation by `mix release`).
  removeCookie = false;

  # Vendor the NIF cache + checksum map before `mix deps.compile` runs
  # (the mdex_native compile happens in configurePhase).
  preConfigure = lib.optionalString isX86_64Linux ''
    cp ${checksumExs} "$MIX_DEPS_PATH/mdex_native/checksum-MDExNative.Native.exs"
  '';

  env = lib.optionalAttrs isX86_64Linux {
    RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH = "${nifCache}";
  };

  # NOTE: the default postFixup strips ${erlang} references and wraps
  # $out/bin with a PATH of coreutils/gnused/gnugrep/gawk. Kept as-is —
  # the P0 consumer smoke passed against this exact shape.
}
