# The Go language capability: the nixpkgs toolchain (floored at the
# retired download pin's minor — operator ruling 2026-10-27: the pins
# machinery is redundant) and the editor profile entry.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # the floor guards the overlay: the pinned 25.05 set carries go 1.24 —
  # the foundation input's current 1.26.x is the declared surface, and an
  # unapplied overlay (or a lagging lock) dies here instead of quietly
  # downgrading the toolchain (the retired pin carried 1.27.1; the locked
  # foundation input carries 1.26.9 — the floor holds the minor, the next
  # flake lock update raises it, nixpkgs owns the drift)
  go =
    assert
      lib.versionAtLeast (pkgs.workstation-go.version or "0") "1.26"
      || throw "workstation-go: pkgs.workstation-go ${
        pkgs.workstation-go.version or "?"
      } predates the floor 1.26 — the flake's overlays.default must be applied (nixpkgs.overlays)";
    # the SCOPED name (pkgs.workstation-go, not pkgs.go): nixpkgs' own `go`
    # is a build toolchain consumed by packages this workstation never
    # touches — libcap builds with it, and retargeting the name rehashed
    # the toolchain's whole dependent world off the binary cache
    pkgs.workstation-go;
in
{
  # the selection gate (workstation.languages.go.enable AND the domain
  # enable — a member deploys under its domain, nix/lib/selections.nix):
  # disabled = the definitions skip, never the files
  config = lib.mkIf (config.workstation.languages.enable && config.workstation.languages.go.enable) {
    home.packages = [ go ];

    workstation.editor.languages = [
      {
        id = "go";
        requires = [ "go" ];
        lazyvim_extras = [ "lazyvim.plugins.extras.lang.go" ];
      }
    ];
  };
}
