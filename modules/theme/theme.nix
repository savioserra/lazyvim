# The theme library: palette and slots parsed from tokens.lua, slot
# rendering for templates.
{ lib }:
let
  lines = lib.splitString "\n" (builtins.readFile ./tokens.lua);

  blockLines =
    name:
    let
      start = lib.lists.findFirstIndex (
        l: l == "M.${name} = {"
      ) (throw "workstation-theme: tokens.lua carries no M.${name} block") lines;
      body = lib.drop (start + 1) lines;
      end = lib.lists.findFirstIndex (
        l: l == "}"
      ) (throw "workstation-theme: M.${name} block is unterminated") body;
    in
    lib.sublist 0 end body;

  sectionLines =
    section: body:
    let
      start = lib.lists.findFirstIndex (
        l: l == "\t${section} = {"
      ) (throw "workstation-theme: tokens.lua carries no ${section} section") body;
      rest = lib.drop (start + 1) body;
      end = lib.lists.findFirstIndex (
        l: l == "\t},"
      ) (throw "workstation-theme: the ${section} section is unterminated") rest;
    in
    lib.sublist 0 end rest;

  parsePairs =
    pattern: ls:
    lib.listToAttrs (
      map (
        l:
        let
          m = builtins.match pattern l;
        in
        if m == null then
          throw "workstation-theme: unparsable token line: ${l}"
        else
          lib.nameValuePair (builtins.elemAt m 0) (builtins.elemAt m 1)
      ) (lib.filter (l: lib.trim l != "") ls)
    );

  slotsBlock = blockLines "slots";
  paletteBlock = blockLines "palette";

  slots = parsePairs ''[[:space:]]*([a-z_]+) = "([a-z]+)",?'' slotsBlock;
  palette = {
    dark = parsePairs ''[[:space:]]*([a-z_]+) = "(#[0-9a-fA-F]{6})",?'' (
      sectionLines "dark" paletteBlock
    );
    light = parsePairs ''[[:space:]]*([a-z_]+) = "(#[0-9a-fA-F]{6})",?'' (
      sectionLines "light" paletteBlock
    );
  };

  assertNonEmpty =
    attrs: what:
    assert attrs != { } || throw "workstation-theme: extracted ${what} is empty";
    attrs;

  renderSlots =
    template:
    let
      names = lib.attrNames slots;
      needles = map (n: "{{ .theme.slots.${n} }}") names;
    in
    builtins.replaceStrings needles (map (n: slots.${n}) names) template;

  assertNoUnresolved =
    rendered:
    assert
      !(lib.hasInfix "{{ .theme.slots." rendered)
      || throw "workstation-theme: a template referenced a slot tokens.lua does not carry";
    rendered;
in
assertNonEmpty slots "slots"
// {
  inherit
    slots
    palette
    renderSlots
    assertNoUnresolved
    ;
  version = builtins.head (lib.filter (l: lib.hasPrefix "M.version" l) lines);
}
