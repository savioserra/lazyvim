# The agent domain's flake outputs: the managed skills surface (consumer
# flakes take these; the HM module links them per profile). One
# constructor per domain - the root flake only wires it.
{ self }:
{
  skills = import ./skills.nix { inherit self; };
}
