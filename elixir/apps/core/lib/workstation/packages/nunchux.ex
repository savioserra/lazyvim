defmodule Workstation.Packages.Nunchux do
  @moduledoc """
  The `nunchux` workstation package's native contribution:
  the pinned launcher binary pre-seed, the platform marker, and the
  theme-slot launcher config.

  The binary is the first package-wired use of the download contract
  (`Workstation.Core.Contracts.Download`): the pinned 3.1.3 linux-x86_64
  release artifact installs at `.tmux/plugins/nunchux/bin/nunchux`, next to
  a chezmoi-owned `.platform` marker ("linux-amd64") — exactly the two files
  upstream's `nunchux.tmux` `ensure_binary` checks, so plugin load never
  fetches `releases/latest` unchecksummed. The download contract pins one
  artifact per declaration, so the package is linux-only today; the
  darwin-arm64 release pin stays recorded in `workstation/versions.json`
  (asserted by the package tests) until per-platform dispatch exists.

  The launcher config rides the same theme envelope the tmux package used
  while the payload was parked there (slot names, rendered bytes equal
  upstream's default config). The tmux-side activation surface — the
  commented `@plugin` pin and the root `C-Space` chord block in
  `.tmux.conf` (tmux-owned target) — stays dormant: the plugin checkout
  itself awaits the git contract's pinned-clone recipe (docs/tmux.md,
  "prepared"), and a live chord today would error on the not-yet-cloned
  plugin. The pre-seeded `bin/` files are what TPM's own clone would fetch:
  once the git recipe lands, the checkout and the pre-seed compose instead
  of racing TPM's installer.
  """

  @behaviour Workstation.Core.Catalog.Spec

  alias Workstation.Core.Catalog.Packages
  alias Workstation.Core.Contracts.Download

  @version "3.1.3"
  # workstation/versions.json is the pin inventory; these literals mirror its
  # nunchux_linux_x86_64_* records and are asserted byte-equal by the package
  # tests (the tmux-oasis pin-mirror pattern).
  @sha256 "d66afe3d47272a41272fe8c22bf86c8b8570fa2e5dbf0a1c462348d0cdf04c29"

  @spec spec() :: map()
  def spec do
    %{
      foundation: "foundation/terminal",
      id: "nunchux",
      requires: ["foundation", "theme"],
      supported_hosts: %{"darwin" => false, "linux" => true},
      contributes: [
        download_binary(),
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

  # The pinned release artifact, downloaded straight into the TPM plugin
  # checkout's bin/ directory (0755 by the download contract), with the
  # platform marker beside it: the pre-seed that keeps upstream's
  # ensure_binary from ever fetching.
  defp download_binary do
    %{
      provider: Download.provider_id(),
      spec:
        Download.recipe(%{
          url: "https://github.com/datamadsen/nunchux/releases/download/v#{@version}/nunchux-linux-amd64",
          version: @version,
          sha256: @sha256,
          target: ".tmux/plugins/nunchux/bin/nunchux"
        })
    }
  end
end
