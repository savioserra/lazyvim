defmodule Workstation.Core.Catalog.Packages.Tmux do
  @moduledoc """
  The `tmux` workstation package's native contribution:
  the managed tmux configuration, its theme template and the XDG link.

  The bar's palette-role block renders from the theme capability's
  .chezmoidata.toml envelope (hence the template flag and the theme
  requirement); the layout and segments stay static. The XDG tmux config
  stays a link to the managed legacy config so TPM keeps loading the pinned
  plugin root. Plugin checkouts (tpm/tmux2k/yank/navigator/resurrect at
  pinned commits) are the factory's Lua `setup`/`verify` handlers, never
  managed source state.

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
        Packages.chezmoi(
          target: ".config/tmux/themes/tmux2k.conf",
          kind: :file,
          template: true,
          asset: "files/.config/tmux/themes/tmux2k.conf"
        ),
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
