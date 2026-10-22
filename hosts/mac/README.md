# The mac leg (nix-darwin, brew reduced to casks)

The mac runs the substrate through nix-darwin with the home-manager
module integrated. Brew keeps ONLY casks (GUI apps); every CLI formula
retires into the nix set, and the eval ENFORCES it:

- `hosts/mac/retired-brew.nix` — the retired-from-brew formula list
  (operator data, seeded with tmux + btop: the substrate's terminal pins
  are nixpkgs-owned on the substrate). A formula may only be appended
  AFTER its nix package exists in `hosts/mac/default.nix`'s
  `nixPackages` — the eval fails naming any retired formula nix does not
  own.

The rebuild key is DERIVED from `hosts/mac/default.nix`'s identity block
(`${user}@${hostName}`) — that file is the only place the host's user and
hostname live; flip them there and the darwin user, the HM user and the
rebuild key all follow.

## Apply (on the mac host)

```sh
# from a clone of the program's anchor repo (the nix substrate remote):
darwin-rebuild switch --flake .#<user>@<hostname>

# the mutating seam (--system wraps darwin-rebuild on this host):
workstation-switch apply --system
```

## Proof status (2026-10-22)

- eval green target: `darwinConfigurations."mac@mac"` toplevel —
  evaluated on the x86_64 runner, where the aarch64-darwin engine
  derivation evals clean (the named gap: per-target NIF vendoring is
  open, so the first real switch must BUILD the engine on the mac).
- the daemon's darwin shape: no launchd agent yet — HM's launchd surface
  does not exist inside the nix-darwin-integrated home module, so the
  daemon starts on demand (the CLI's ensure-daemon spawn covers the
  `system` domain receipt). A launchd agent is a mac-cutover follow-up.
- consumer smoke + live apply + `brew leaves` enumeration: NOT run — the
  mac host was unreachable from the runner (ssh `mac`: connection timed
  out; re-verified 2026-10-22). When reachable: enumerate `brew leaves`,
  extend `retired-brew.nix` (the eval enforces nix ownership per entry),
  switch, then consumer-smoke `workstation --version` + the nvim profile
  link.
