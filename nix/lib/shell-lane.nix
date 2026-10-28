# The shell fragment lane's ORDER CONTRACT. The rc lane's composition order
# is PATH semantics — and PATH semantics live on ONE GLOBAL SCALE: the
# round-tens `order` is the fragment's slot in the composed rc file (the
# user-local bin fragment leads at 10, the secrets op-env rides 30, the
# aliases own the 40s, the per-shell prompt init the 50s/60s, the editor
# env 70, the direnv hook 80/90), so cross-capability composition compares
# the numbers NUMERICALLY — never lexicographically (a "/100" slot must
# trail "/90", not slot between "/10" and "/20"). A new capability slots
# its fragments between its neighbours' numbers without renumbering
# anyone.
#
# Mechanically: each fragment carries `order` (its round-tens rc slot on
# the shared scale), `domain` (its declaring capability's id — the sort's
# tiebreak, so distinct domains sharing a number compose in registry
# order), and the optional trailing rank (`trailing`, the operator's
# override plane). The ONE sort both consumers read (the home leg's
# rendered rc files and the report fold's fragmentOrder) composes by
# (trailing, order, domain) — the managed lanes first in slot order, then
# the operator's fragment after every domain (the foundation shell.extras
# contract: the operator's lines compose last and may override them). The
# module system's reverse-listOf merge is deliberately not the contract.
#
# The contract fails the eval on ambiguity: one id carries exactly one
# slot and one domain, and two distinct ids of the SAME domain may not
# share a slot ON THE SAME TARGET (which one sources first there is
# exactly the PATH semantics the domain exists to declare — never a silent
# tie-break). The same (domain, slot) on disjoint targets is the per-shell
# body pair (managed-eza / managed-eza-zsh) and never composes in one rc
# file. Distinct domains sharing a number is by design — the numbers are
# the shared scale and compose deterministically.
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
          inherit id;
          order = builtins.head orders;
          domain = builtins.head domains;
          targets = lib.unique (map (f: f.target) own);
          inherit orders domains;
        }
      ) ids;

      ambiguous = lib.filter (s: lib.length s.orders != 1 || lib.length s.domains != 1) idSlots;

      # a slot claimed by two distinct ids of the SAME domain on the SAME
      # target is an ambiguous lane (which one sources first there is
      # exactly the PATH semantics the domain exists to declare) — never a
      # silent tie-break
      slotGroups = lib.mapAttrsToList (_: ss: ss) (
        builtins.groupBy (s: s.domain + "/" + toString s.order) idSlots
      );
      shared = lib.filter (
        ss:
        let
          claimed = lib.concatMap (s: s.targets) ss;
        in
        lib.length ss > 1 && lib.length claimed != lib.length (lib.unique claimed)
      ) slotGroups;
      sharedNames = map (
        ss:
        "order ${toString (builtins.head ss).order} of domain ${
          lib.concatStringsSep ", " (lib.unique (map (s: s.domain) ss))
        }: ${lib.concatStringsSep " + " (map (s: s.id) ss)}"
      ) shared;

      # the composition key: the trailing rank first (the managed lanes,
      # then the operator's override plane), then the NUMERIC order (the
      # global round-tens scale — a list key, so `order` never degrades to
      # a string compare), then the domain (the registry-order tiebreak
      # for shared numbers)
      laneKey = f: [
        (if (f.trailing or false) then 1 else 0)
        f.order
        (f.domain or "")
      ];
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
      || throw "workstation-shell: fragments of the same domain share an order slot on one target (${lib.concatStringsSep "; " sharedNames}) — the order is the rc file's PATH semantics; give each id its own slot";
    lib.sort (a: b: laneKey a < laneKey b) fragments;
in
{
  inherit sortedFragments;
}
