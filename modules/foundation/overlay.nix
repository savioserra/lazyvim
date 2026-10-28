# The foundation domain's tool overrides: the tools this capability owns,
# sourced from the domain's toolchain input (nixpkgs-foundation).
foundationPkgs:
final: prev: {
  harlequin = foundationPkgs.harlequin;
  fd = foundationPkgs.fd;
  fzf = foundationPkgs.fzf;
  ripgrep = foundationPkgs.ripgrep;
  lazygit = foundationPkgs.lazygit;
  pnpm = foundationPkgs.pnpm;
  _1password-cli = foundationPkgs._1password-cli;
  nerd-fonts = foundationPkgs.nerd-fonts;
}
