# The mac leg (nix-darwin)

The mac runs the substrate through nix-darwin with the home-manager module
integrated. Homebrew is a managed dependency: `nix-homebrew` installs it at
the default prefix from the brew release its lock pins (an existing
install is taken over, its installed packages kept), and nix-darwin's
`homebrew.*` options declare what it installs. `nix flake update
nix-homebrew` moves the brew pin. The machine file (`hosts/machine.json`, written by
`workstation init`) carries the user, the host name and the settings; the
darwin configuration key is `<user>@<host>`.

## Apply

```sh
workstation apply --system   # darwin-rebuild switch over the committed HEAD
workstation rollback --system
```

The home plane rides the system switch; `workstation apply` without
`--system` has no target on this leg and exits 2 naming the fix.
