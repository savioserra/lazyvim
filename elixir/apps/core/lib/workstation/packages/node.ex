defmodule Workstation.Packages.Node do
  @moduledoc """
  The `node` workstation package's native contribution:
  the sole Node version pin asset, the managed nvm shell loader and its
  startup-file fragments.

  The archive bootstrap and runtime configuration stay with the factory's
  Lua `setup` handler (`packages/node/unix`); versions.lua stays target-only
  and nil-tolerant, and `workstation apply` refreshes the `.node-version` pin
  in place before setup, so the native surface is exactly the two assets plus
  the three loader fragments.
  """

  @behaviour Workstation.Core.Catalog.Spec

  alias Workstation.Core.Catalog.Packages

  @startup_files [".profile", ".bashrc", ".zshrc"]

  @fragment %{
    id: "managed-nvm",
    order: 20,
    marker: "# chezmoi: load managed nvm",
    body: "[ -r \"$HOME/.config/shell/nvm.sh\" ] && . \"$HOME/.config/shell/nvm.sh\""
  }

  @spec spec() :: map()
  def spec do
    contributions = [
      Packages.chezmoi(target: ".node-version", kind: :file, asset: "files/.node-version"),
      Packages.chezmoi(target: ".config/shell/nvm.sh", kind: :file, asset: "files/nvm.sh")
    ]

    %{
      foundation: "foundation/runtime",
      id: "node",
      requires: ["foundation"],
      supported_hosts: nil,
      contributes: contributions ++ Enum.map(@startup_files, &Packages.shell(&1, @fragment))
    }
  end
end
