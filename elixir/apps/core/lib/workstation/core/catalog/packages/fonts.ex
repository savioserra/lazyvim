defmodule Workstation.Core.Catalog.Packages.Fonts do
  @moduledoc """
  The `fonts` workstation package's native contribution:
  catalog ordering only, with no managed home target.

  Fonts deploys no managed home target: the Nerd Font payload is unpacked by
  the platform backend the factory's Lua `setup`/`verify` handlers delegate
  to (`packages.fonts.linux` / `packages.fonts.darwin`), which is exactly why
  the package exists in the graph — it orders the platform font setup after
  foundation without contributing engine-rendered state.
  """

  @behaviour Workstation.Core.Catalog.Spec

  @spec spec() :: map()
  def spec do
    %{
      foundation: "foundation/fonts",
      id: "fonts",
      requires: ["foundation"],
      supported_hosts: nil,
      contributes: []
    }
  end
end
