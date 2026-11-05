# The machine file (hosts/machine.json, written by `workstation init`,
# kept uncommitted): identity plus `settings`, a home-manager option tree.
{ lib, root }:
let
  m = lib.importJSON (root + "/hosts/machine.json");
  settings = m.settings or { };
in
{
  inherit (m) host user home;
  system = m.system or "x86_64-linux";
  key = "${m.user}@${m.host}";
  inherit settings;
  networkEnable = settings.workstation.network.enable or false;

  homeModules = [
    { config = settings; }
    {
      home.username = m.user;
      home.homeDirectory = m.home;
      programs.hermes.a2a.name = m.host;
      programs.hermes.a2a.peers = import (root + "/hosts/peers.nix");
    }
  ];
}
