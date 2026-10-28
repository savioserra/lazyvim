# Workstation foundation fragment: the user-local bin and the home-manager
# profile on PATH (the hm profile is where home.packages land on
# standalone-HM legs; the Determinate system profile.d does not carry it).
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) [ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH" ;;
esac
case ":$PATH:" in
  *":$HOME/.nix-profile/bin:"*) ;;
  *) [ -d "$HOME/.nix-profile/bin" ] && PATH="$HOME/.nix-profile/bin:$PATH" ;;
esac
