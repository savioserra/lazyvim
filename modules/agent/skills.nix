# The agent domain's skill payload paths — the single source both the
# agent module (the option defaults) and the flake's hermesSkills output
# import. The bytes live beside this module (the co-located payload).
{ self }:
{
  secrets = ./files/.hermes/skills/secrets;
}
