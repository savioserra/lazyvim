# The languages domain: the members are the granularity.
{ lib, ... }:
{
  options.workstation.languages.enable = lib.mkEnableOption "the language toolchains" // {
    default = true;
  };
}
