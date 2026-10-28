# The shell fragment lane's ORDER CONTRACT. The rc lane's composition order
# is PATH semantics — and PATH semantics are CAPABILITY-LOCAL: a capability
# orders its own fragments (the user-local bin fragment must lead the
# foundation lane, the prompt must trail it) and never reasons about
# another capability's slots. Cross-capability composition is the
# (domain, order) key, so a new capability needs no knowledge of the lane's
# existing numbers.
#
# Mechanically: each fragment carries `domain` (its own capability id)
# and `order` (a slot in ITS domain's lane), plus the optional trailing
# rank (`trailing`, the operator's override plane): the ONE sort both
# consumers read (the home leg's rendered rc files and the report fold's
# fragmentOrder) composes by (trailing, domain, order) — the domains'
# lanes first, then the operator's fragment after every domain (the
# foundation shell.extras contract: the operator's lines compose last
# and may override the managed ones). The module system's reverse-listOf
# merge is deliberately not the contract.
#
# The contract fails the eval on ambiguity: one id carries exactly one
# slot, and two distinct ids of the SAME domain may not share a slot.
# Distinct domains sharing a number is by design — their numbers are
# different lanes.
{ lib }:
let
  sortedFragments =
    fragments:
    let
      # the same fragment id may deploy to many targets (one body, three
      # rc files); it always carries exactly one slot and one domain
      ids = lib.unique (map (f: f.id) fragments);
      idSlots = map (
        id:
        let
          own = lib.filter (f: f.id == id) fragments;
          orders = lib.unique (map (f: f.order) own);
          domains = lib.unique (map (f: f.domain or "") own);
        in
        {
          inherit id domains;
          order = builtins.head orders;
          orders = orders;
        }
      ) ids;

      ambiguous = lib.filter (s: lib.length s.orders != 1 || lib.length s.domains != 1) idSlots;
      slots = map (s: {
        inherit (s) id;
        domain = s.domain or "";
        order = builtins.head s.orders;
      }) idSlots;

      # a slot claimed by two distinct ids of the SAME domain is an
      # ambiguous lane (which one sources first is exactly the PATH
      # semantics the domain exists to declare) — never a silent tie-break.
      # Distinct domains sharing a number compose in registry order: their
      # numbers are different lanes and never compared.
      lanes = lib.mapAttrsToList (_: ss: ss) (builtins.groupBy (s: s.domain or "") slots);
      shared = lib.filter (
        ss:
        let
          core = map (s: {
            inherit (s) domain order;
          }) ss;
        in
        lib.length ss > 1 && lib.length (lib.unique core) == lib.length ss
      ) lanes;
      sharedNames = map (
        ss: "order ${toString (builtins.head ss).order}: ${lib.concatStringsSep " + " (map (s: s.id) ss)}"
      ) shared;

      # the composition key: the trailing rank first (the managed lanes,
      # then the operator's override plane), then the (domain, order)
      # lane key
      laneKey =
        f: (if (f.trailing or false) then "1" else "0") + (f.domain or "") + "/" + toString f.order;
    in
    assert
      ambiguous == [ ]
      || throw "workstation-shell: fragment ids declare conflicting orders or domains across targets (${
        lib.concatStringsSep ", " (
          map (
            s:
            "${s.id}: ${lib.concatStringsSep " vs " (map toString s.orders)} / domain ${lib.concatStringsSep " vs " s.domains}"
          ) ambiguous
        )
      }) — one fragment, one order slot, one domain";
    assert
      shared == [ ]
      || throw "workstation-shell: fragments of the same domain share an order slot (${lib.concatStringsSep "; " sharedNames}) — the order is the domain's PATH semantics; give each id its own slot";
    lib.sort (a: b: laneKey a < laneKey b) fragments;
in
{
  inherit sortedFragments;
}
