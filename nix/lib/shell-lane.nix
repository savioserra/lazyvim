# The shell fragment lane's ORDER CONTRACT. The rc lane's composition order
# is PATH semantics (the user-local bin fragment must lead, the prompt must
# trail), so it is never derived: every fragment declares an integer `order`
# slot and the composition sorts by it — here, once, the ONE sort both
# consumers read (the home leg's rendered rc files and the report fold's
# fragmentOrder), so the lane and its report can never disagree. The merged
# module-system list order is deliberately not the contract: nixpkgs'
# module system merges `listOf` values in REVERSE module order, which no
# reader of "declaration order" would guess and a new domain would flip
# silently.
#
# Slots are declared in round tens so a new fragment slots between
# neighbours without renumbering the lane. The contract fails the eval on
# ambiguity: one id carries exactly one slot, and two distinct ids may not
# share a slot.
{ lib }:
let
  sortedFragments =
    fragments:
    let
      # the same fragment id may deploy to many targets (one body, three
      # rc files); it always carries exactly one slot
      ids = lib.unique (map (f: f.id) fragments);
      idSlots = map (
        id:
        let
          orders = lib.unique (map (f: f.order) (lib.filter (f: f.id == id) fragments));
        in
        {
          inherit id orders;
        }
      ) ids;

      ambiguous = lib.filter (s: lib.length s.orders != 1) idSlots;
      slots = map (s: {
        inherit (s) id;
        order = builtins.head s.orders;
      }) idSlots;

      # a slot claimed by two distinct ids is an ambiguous lane (which one
      # sources first is exactly the PATH semantics the contract exists to
      # declare) — never a silent tie-break
      owners = lib.mapAttrsToList (_: ss: ss) (builtins.groupBy (s: toString s.order) slots);
      shared = lib.filter (ss: lib.length ss > 1) owners;
      sharedNames = map (
        ss: "order ${toString (builtins.head ss).order}: ${lib.concatStringsSep " + " (map (s: s.id) ss)}"
      ) shared;
    in
    assert
      ambiguous == [ ]
      || throw "workstation-shell: fragment ids declare conflicting orders across targets (${
        lib.concatStringsSep ", " (
          map (s: "${s.id}: ${lib.concatStringsSep " vs " (map toString s.orders)}") ambiguous
        )
      }) — one fragment, one order slot";
    assert
      shared == [ ]
      || throw "workstation-shell: distinct fragments share an order slot (${lib.concatStringsSep "; " sharedNames}) — the lane's order is PATH semantics, declared per fragment; give each id its own slot";
    lib.sort (a: b: a.order < b.order) fragments;
in
{
  inherit sortedFragments;
}
