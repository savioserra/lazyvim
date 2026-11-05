# The rc lane order: fragments sort by (trailing, order, domain); an id
# holds one slot; one domain never shares a slot on one target.
{ lib }:
let
  sortedFragments =
    fragments:
    let
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
