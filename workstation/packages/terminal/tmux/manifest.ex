defmodule Workstation.Packages.Tmux do
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

  The nunchux launcher grew into its own terminal-domain package
  (its data manifest, workstation/packages/terminal/nunchux/manifest.json):
  the theme-slot config target, the pinned
  binary pre-seed and the platform marker moved there. This package keeps
  only the dormant activation surface in .tmux.conf — the commented
  `@plugin` pin and the root `C-Space` chord block — which goes live with
  the plugin checkout once the git contract's pinned-clone recipe lands
  (docs/tmux.md, "prepared" section).
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
        Packages.chezmoi(target: ".config/tmux/tmux.conf", kind: :symlink, to: "../../.tmux.conf")
      ]
    }
  end
end
