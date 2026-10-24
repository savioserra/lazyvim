# The theme domain: tokens.lua is the canonical byte source and nix reads
# it directly (docs/absorption.md — the chezmoi-data refusal lane retires:
# the envelope was the token table's chezmoi-side projection, and nothing
# deploys — the theme capability owns data, not home targets).
#
# The extraction is a fail-closed line parse of the token module's closed
# blocks (M.slots, M.palette.dark, M.palette.light): every listed key must
# exist, every value must match its block's value shape, and the extracted
# set is asserted non-empty — a tokens.lua restructure that the parser can
# no longer read fails the eval loudly, never silently renders empty
# tokens. Consumers substitute slots into their templates
# (workstationTheme.lib exposes the surface; the flake output carries it).
{
  lib,
  self,
}:
let
  lines = lib.splitString "\n"
    (builtins.readFile ./tokens.lua);

  # the lines of a closed `M.<name> = {` ... `}` block
  blockLines = name:
    let
      start = lib.lists.findFirstIndex (l: l == "M.${name} = {")
        (throw "workstation-theme: tokens.lua carries no M.${name} block") lines;
      body = lib.drop (start + 1) lines;
      end = lib.lists.findFirstIndex (l: l == "}")
        (throw "workstation-theme: M.${name} block is unterminated") body;
    in
    lib.sublist 0 end body;

  # the lines of a nested `<name> = {` ... `<tab>},` section inside a block
  sectionLines = section: body:
    let
      start = lib.lists.findFirstIndex (l: l == "\t${section} = {")
        (throw "workstation-theme: tokens.lua carries no ${section} section") body;
      rest = lib.drop (start + 1) body;
      end = lib.lists.findFirstIndex (l: l == "\t},")
        (throw "workstation-theme: the ${section} section is unterminated") rest;
    in
    lib.sublist 0 end rest;

  parsePairs = pattern: ls:
    lib.listToAttrs (map
      (l:
        let
          m = builtins.match pattern l;
        in
        if m == null then
          throw "workstation-theme: unparsable token line: ${l}"
        else lib.nameValuePair (builtins.elemAt m 0) (builtins.elemAt m 1))
      (lib.filter (l: lib.trim l != "") ls));

  slotsBlock = blockLines "slots";
  paletteBlock = blockLines "palette";

  slots = parsePairs ''[[:space:]]*([a-z_]+) = "([a-z]+)",?'' slotsBlock;
  palette = {
    dark = parsePairs ''[[:space:]]*([a-z_]+) = "(#[0-9a-fA-F]{6})",?''
      (sectionLines "dark" paletteBlock);
    light = parsePairs ''[[:space:]]*([a-z_]+) = "(#[0-9a-fA-F]{6})",?''
      (sectionLines "light" paletteBlock);
  };

  # fail closed on an empty extraction (a restructured tokens.lua the
  # parser cannot read must die here, not render empty tokens downstream)
  assertNonEmpty = attrs: what:
    assert attrs != { } || throw "workstation-theme: extracted ${what} is empty";
    attrs;

  # the substitution helper: one replaceStrings call for every extracted
  # slot, `{{ .theme.slots.<name> }}` -> the slot value
  renderSlots = template:
    let
      names = lib.attrNames slots;
      needles = map (n: "{{ .theme.slots.${n} }}") names;
    in
    builtins.replaceStrings needles (map (n: slots.${n}) names) template;

  assertNoUnresolved = rendered:
    assert !(lib.hasInfix "{{ .theme.slots." rendered)
      || throw "workstation-theme: a template referenced a slot tokens.lua does not carry";
    rendered;
in
assertNonEmpty slots "slots" // {
  inherit slots palette renderSlots assertNoUnresolved;
  version = builtins.head (lib.filter (l: lib.hasPrefix "M.version" l) lines);
}
