defmodule Workstation.Packages.HerdrPi do
  @moduledoc """
  The `herdr-pi` workstation package's native contribution:
  the single managed artifact is the exact official hook bytes bundled
  with the pinned Herdr release (integration revision 8).

  The file recipe deploys through the engine backend; an unmanaged existing
  file fails closed at apply and takeover is always an explicit operator
  decision, matching upstream's single-file contract. Drift/discovery
  verification stays with the factory's Lua `verify` handler.
  """

  @behaviour Workstation.Core.Catalog.Spec

  alias Workstation.Core.Catalog.Packages

  @hook_target ".pi/agent/extensions/herdr-agent-state.ts"

  @spec spec() :: map()
  def spec do
    %{
      foundation: "foundation/agent",
      id: "herdr-pi",
      requires: ["agent", "herdr"],
      supported_hosts: nil,
      contributes: [
        Packages.chezmoi(target: @hook_target, kind: :file, asset: "files/#{@hook_target}")
      ]
    }
  end
end
