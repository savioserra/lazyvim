defmodule Workstation.Packages.Nunchux do
  @moduledoc """
  The `nunchux` workstation package's native contribution: the pinned
  plugin checkout, the platform marker, and the theme-slot launcher
  config.

  The checkout is the first package-wired use of the pinned-clone recipe
  (`Workstation.Packages.Git`): upstream `datamadsen/nunchux` is cloned to
  `.tmux/plugins/nunchux` at the exact v3.1.3 commit — the pin that owns
  every checkout byte, including the `bin/nunchux` launcher binary the
  repo itself tracks (a linux-amd64 build of the same 3.1.3 release,
  content-pinned by `nunchux_repo_linux_amd64_sha256` in
  `workstation/versions.json` and asserted by the verify lane). The clone
  replaced the interim download-contract pre-seed: upstream tracks
  `bin/nunchux`, and the download contract refuses to overwrite mismatched
  bytes, so the release artifact and the checkout could not compose at one
  path. The release-asset pins stay recorded in `versions.json` as the
  upstream distribution inventory.

  The chezmoi `.platform` marker ("linux-amd64") is the load-bearing
  pre-seed: upstream's `nunchux.tmux` `ensure_binary` re-downloads from
  `releases/latest` unchecksummed whenever `bin/.platform` is missing or
  names another platform — with the marker present, plugin load runs the
  commit-pinned repo binary and never fetches.

  The launcher config rides the same theme envelope the tmux package used
  while the payload was parked there (slot names, rendered bytes equal
  upstream's default config). The tmux-side activation surface is live:
  the `@plugin` pin and the root `C-Space` chord block in `.tmux.conf`
  (tmux-owned target) went live with the checkout (docs/tmux.md).
  """

  @behaviour Workstation.Core.Catalog.Spec

  alias Workstation.Core.Catalog.Packages
  alias Workstation.Packages.Git
  @compile {:no_warn_undefined, Workstation.Packages.Git}

  # workstation/versions.json is the pin inventory; these literals mirror
  # its nunchux_git_* records (the v3.1.3 checkout) and are asserted
  # byte-equal by the package tests (the tmux-oasis pin-mirror pattern).
  @repo_url "https://github.com/datamadsen/nunchux"
  @commit "1546eaa980d834c331496ea9d51942be07ea9fdd"

  @spec spec() :: map()
  def spec do
    %{
      foundation: "foundation/terminal",
      id: "nunchux",
      requires: ["foundation", "theme"],
      supported_hosts: %{"darwin" => false, "linux" => true},
      contributes: [
        pinned_checkout(),
        Packages.chezmoi(
          target: ".tmux/plugins/nunchux/bin/.platform",
          kind: :file,
          asset: "files/.tmux/plugins/nunchux/bin/.platform"
        ),
        Packages.chezmoi(
          target: ".config/nunchux/config",
          kind: :file,
          template: true,
          asset: "files/.config/nunchux/config"
        )
      ]
    }
  end

  # The pinned plugin checkout: the whole TPM plugin dir as a detached-HEAD
  # clone verified against the commit. The clone lands first (per-target
  # phase, before the staged-generation apply effect); the chezmoi marker
  # and config ride into the cloned tree with the apply.
  defp pinned_checkout do
    %{
      provider: Git.id(),
      spec:
        Git.recipe(%{
          url: @repo_url,
          commit: @commit,
          target: ".tmux/plugins/nunchux"
        })
    }
  end
end
