defmodule Workstation.Core.Catalog.Packages.Secrets do
  @moduledoc """
  The `secrets` workstation package's native contribution:
  only the op environment loader fragment.

  Secret values never enter the engine (vault work requires explicit user
  invocation); the 1Password CLI archive is the factory's Lua `setup`
  handler, so the managed surface is exactly the `.profile` fragment that
  sources `/etc/pi/op.env` when present. Order 30 slots it between the nvm
  (20) and ntfy (40) fragments on the shared startup file.
  """

  alias Workstation.Core.Catalog.Packages

  @spec spec() :: map()
  def spec do
    %{
      id: "secrets",
      requires: ["foundation"],
      supported_hosts: nil,
      contributes: [
        Packages.shell(".profile", %{
          id: "managed-op-env",
          order: 30,
          marker: "# chezmoi: managed op env",
          body: "[ -r /etc/pi/op.env ] && { set -a; . /etc/pi/op.env; set +a; }"
        })
      ]
    }
  end
end
