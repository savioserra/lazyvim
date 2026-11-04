# The agent domain's helper programs: the payload scripts with their tools
# in the closure (PATH-independent).
#
# | Program | Consumer |
# | --- | --- |
# | workstation-a2a-converge | the A2A activation (programs.hermes.a2a) |
# | workstation-peers | `workstation peers` — tailnet discovery into hosts/peers.nix |
{ pkgs }:
{
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
    ];
    bashOptions = [ ];
    text = builtins.readFile ./files/a2a-peers.sh;
  };
}
