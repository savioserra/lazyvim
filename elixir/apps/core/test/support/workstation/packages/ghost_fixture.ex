defmodule Workstation.Packages.GhostFixture do
  @moduledoc """
  A CONFORMING package-spec provider that lives under `test/support` — the
  deterministic test-tree exclusion case. Discovery must never admit it
  into the live catalog (its source path contains `/test/`), so the catalog
  stays exactly the fifteen native packages. If the exclusion ever breaks,
  `Workstation.Core.Catalog.DiscoverTest` and the golden byte anchors fail
  together.
  """

  @behaviour Workstation.Core.Catalog.Spec

  @impl Workstation.Core.Catalog.Spec
  def spec do
    %{
      foundation: "foundation/base",
      id: "ghost-fixture",
      requires: [],
      supported_hosts: nil,
      contributes: []
    }
  end
end
