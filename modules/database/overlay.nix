# The database domain's override: harlequin rides the foundation domain's
# toolchain input (the pinned set predates hsql).
foundationPkgs:
final: prev: {
  harlequin = foundationPkgs.harlequin;
}
