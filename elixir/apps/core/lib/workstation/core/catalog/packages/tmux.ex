defmodule Workstation.Core.Catalog.Packages.Tmux do
  @moduledoc """
  The `tmux` workstation package's native contribution:
  the managed tmux configuration, the retired tmux2k target's removal
  tombstone and the XDG link.

  The status bar is the pinned tmux-oasis plugin's own six-module layout at
  the upstream `starlight_dark` flavor: `.tmux.conf` carries only the plugin
  pin and the flavor option (both ahead of TPM init, upstream's README
  install pattern) and deliberately sets no `@thm_*` options — upstream's
  themes/dark/oasis_starlight_dark.conf is canonical, so the theme
  requirement stays only for the nunchux launcher template. The XDG tmux
  config stays a link to the managed legacy config so TPM keeps loading the
  pinned plugin root. Plugin checkouts (tpm/tmux-oasis/yank/navigator/
  resurrect at pinned commits) are provisioning contracts recorded in
  docs/tmux.md, never managed source state.

  The nunchux launcher config rides the same theme envelope (slot names,
  rendered bytes equal upstream's default config), but the plugin itself
  stays dormant: the `@plugin` line in .tmux.conf is commented out until
  the engine grows download provisioning — upstream's nunchux.tmux fetches
  `releases/latest` at plugin load with no checksum, so activation is
  gated on checksummed pre-seeding (docs/tmux.md, "prepared" section).
  """

  @behaviour Workstation.Core.Catalog.Spec

  alias Workstation.Core.Catalog.Packages

  @spec spec() :: map()
  def spec do
    %{
      foundation: "foundation/terminal",
      id: "tmux",
      requires: ["foundation", "theme"],
      supported_hosts: %{"darwin" => true, "linux" => true},
      contributes: [
        Packages.chezmoi(target: ".tmux.conf", kind: :file, asset: "files/.tmux.conf"),
        # The retired tmux2k slot template: recorded-ownership tombstone so a
        # previously applied home drops the target (already-absent no-op).
        Packages.chezmoi(target: ".config/tmux/themes/tmux2k.conf", kind: :remove),
        Packages.chezmoi(
          target: ".config/nunchux/config",
          kind: :file,
          template: true,
          asset: "files/.config/nunchux/config"
        ),
        Packages.chezmoi(target: ".config/tmux/tmux.conf", kind: :symlink, to: "../../.tmux.conf")
      ]
    }
  end
end
