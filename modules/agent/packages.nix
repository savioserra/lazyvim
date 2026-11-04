# The agent domain's helper programs: the payload scripts with their tools
# in the closure (PATH-independent).
#
# | Program | Consumer |
# | --- | --- |
# | workstation-a2a-converge | the A2A activation (programs.hermes.a2a) |
# | workstation-a2a-token | the pair-token store (stdin value) for peers and the fleet |
# | workstation-peers | `workstation peers` — the hub over the tailnet's agents |
# | workstation-fleet | the fleet member service and `workstation fleet` joins |
{ pkgs }:
let
  workstation-a2a-token = pkgs.writeShellApplication {
    name = "workstation-a2a-token";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
    ];
    bashOptions = [ ];
    text = builtins.readFile ./files/a2a-token.sh;
  };
in
{
  inherit workstation-a2a-token;

  workstation-a2a-converge = pkgs.writeShellApplication {
    name = "workstation-a2a-converge";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.tailscale
      pkgs.yq-go
    ];
    bashOptions = [ ];
    text = builtins.readFile ./files/a2a-converge.sh;
  };

  workstation-peers = pkgs.writeShellApplication {
    name = "workstation-peers";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
      pkgs.newt
      pkgs.socat
      pkgs.tailscale
      workstation-a2a-token
    ];
    bashOptions = [ ];
    text = builtins.readFile ./files/a2a-peers.sh;
  };

  workstation-fleet = pkgs.writeShellApplication {
    name = "workstation-fleet";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
      pkgs.socat
      pkgs.tailscale
      workstation-a2a-token
    ];
    bashOptions = [ ];
    text = builtins.readFile ./files/a2a-fleet.sh;
  };
}
