# The agent domain's override: the interpreter, floored at the pinned
# rev's lock. Global by design - nothing in nixpkgs consumes python314
# as a build input.
foundationPkgs:
final: prev: {
  python314 = foundationPkgs.python314;
}
