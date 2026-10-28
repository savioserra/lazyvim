# The languages domain's overrides: the toolchains are SCOPED - go/node
# are nixpkgs build toolchains consumed by packages this workstation
# never touches; retargeting them rebuilds nixpkgs' own consumers.
foundationPkgs:
final: prev: {
  workstation-go = foundationPkgs.go;
  workstation-node = foundationPkgs.nodejs_24;
}
