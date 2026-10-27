# The container E2E persona's capability selection — the FULL fixture: the
# languages the driver asserts (go/elixir entries in the composed profile,
# node/pnpm/go on PATH), pinned on. A tracked fixture, never the operator's
# hosts/selections.nix — the lane stays hermetic against local state. The
# removal proof re-applies the same persona with e2e-selections-minus-go.nix
# (go deselected): the toolchain leaves, the rest rides, nvim still boots.
{
  enable = [
    "languages/elixir"
    "languages/go"
    "languages/node"
    "languages/typescript"
  ];
}
