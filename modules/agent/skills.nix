# The agent domain's skill payload paths — the single source both the
# agent module (the option defaults) and the flake's hermesSkills output
# import. Payload bytes live under workstation/packages/agent/files/ until
# the co-location card renames them beside this module.
{ self }:
{
  secrets = self + "/workstation/packages/agent/files/.hermes/skills/secrets";
}
