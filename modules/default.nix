# The capability modules: every domain and member, imported on every leg;
# each gates itself on its own enable option.
{
  imports = [
    ./agent/agent.nix
    ./database/database.nix
    ./editor/editor.nix
    ./fonts/fonts.nix
    ./foundation/foundation.nix
    ./languages/languages.nix
    ./languages/elixir/elixir.nix
    ./languages/go/go.nix
    ./languages/node/node.nix
    ./languages/typescript/typescript.nix
    ./network/network.nix
    ./secrets/secrets.nix
    ./terminal/terminal.nix
    ./terminal/nunchux/nunchux.nix
    ./terminal/tmux/tmux.nix
    ./theme/tokens.nix
  ];
}
