defmodule Workstation.Core.Catalog.Packages.Theme do
  @moduledoc """
  The `theme` workstation package's native contribution:
  the canonical workstation color tokens published as the generation's
  .chezmoidata.toml envelope.

  The package deploys no home target of its own; consumers (tmux, agent)
  render their templates against the merged data through their own recipes
  and require this package so the envelope is always present whenever they
  are selected. Foundation is the catalog discipline for every HOME-writing
  capability: it keeps theme ordered with the other dependents, after runtime
  setup. The envelope bytes come from `Workstation.Core.Theme.Tokens`, whose
  ExUnit parity anchor pins them to the Lua renderer — a tokens drift fails
  there instead of silently rebranding the home.
  """

  @behaviour Workstation.Core.Catalog.Spec

  alias Workstation.Core.Catalog.Packages

  @spec spec() :: map()
  def spec do
    %{
      foundation: "foundation/theme",
      id: "theme",
      requires: ["foundation"],
      supported_hosts: %{"darwin" => true, "linux" => true},
      contributes: [Packages.theme_data()]
    }
  end
end
