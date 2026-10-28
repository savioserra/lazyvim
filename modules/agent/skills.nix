# The agent domain's authored skill payload paths — the single source both
# the agent capability (the option defaults) and the agent module's
# output import. The bytes live beside the module (the co-located payload);
# each tree serves as ONE entry symlink per target profile
# (programs.hermes.skills — never copied into hot home).
{ self }:
{
  secrets = ./skills/secrets;
}
