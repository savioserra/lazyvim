# The machine files (the flake's machine-files input: hosts/ in the
# checkout's working tree): machine.json, identity plus `settings`, a
# home-manager option tree; peers.nix, the A2A peers.
{ lib, root }:
let
  m = lib.importJSON (root + "/machine.json");
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
      workstation.switch.checkout = m.checkout or null;
      programs.hermes.a2a.name = m.host;
      programs.hermes.a2a.peers = import (root + "/peers.nix");
    }
  ];
}
