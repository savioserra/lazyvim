defmodule Workstation.Core.ArchitectureDepsTest do
  @moduledoc """
  Zero-attraction dependency guards (source scans as ExUnit).

  The scanners are the shared primitives in `Workstation.Core.ArchitectureLaw`
  (test support); `Workstation.Core.LayerLawTest` self-tests those primitives
  against planted violating fixtures, so the scans are proven able to fail
  and not merely passing tautologically.

    1. **The theme capability is a GENERIC engine.** Its engine modules
       (`Workstation.Core.Theme`, `Workstation.Core.Theme.Tokens`, the CLI
       and daemon theme resolvers) must never name a concrete consumer
       package. Consumers derive from the theme tokens in their own
       capability modules — natively, under `modules/` — which the engine
       never names.

    2. **Generic core names no consumer.** Domain modules must not reference
       concrete consumer packages: the declared state is the capability
       modules' report, and the engine speaks shapes, never consumers.

  (The backend-isolation and encoding laws retired with the chezmoi backend
  in the absorption chain's stage 2 — the dialect they guarded has no
  speaker left.)
  """

  use ExUnit.Case, async: true

  import Workstation.Core.ArchitectureLaw

  @elixir_root Path.expand("../../../../..", __DIR__)

  @theme_engine_files [
    "apps/core/lib/workstation/core/theme.ex",
    "apps/core/lib/workstation/core/theme/tokens.ex",
    "apps/cli/lib/workstation/cli/tui/theme.ex",
    "apps/daemon/lib/workstation/daemon/capabilities/theme.ex"
  ]

  describe "theme engine purity" do
    test "theme engine modules never name a concrete consumer package" do
      for rel <- @theme_engine_files do
        source = read(rel)

        violations = consumer_violations(source)

        assert violations == [],
               "#{rel} references consumer packages #{inspect(violations)} — " <>
                 "consumers derive from the theme tokens in their own capability modules"
      end
    end
  end

  describe "core domain purity" do
    test "generic core code never names a consumer package" do
      for rel <- core_files() do
        code = code_lines(read(rel))

        consumer_hits = consumer_violations(code)

        assert consumer_hits == [],
               "#{rel} names consumer packages #{inspect(consumer_hits)} — " <>
                 "the declared state is the capability modules' report; the engine speaks shapes"
      end
    end
  end

  # The scan set is the Workstation.Core namespace itself: kernel machinery
  # and the report reader. There is no consumer namespace left in lib.
  defp core_files do
    Path.wildcard(Path.join(@elixir_root, "apps/core/lib/workstation/core/**/*.ex"))
    |> Enum.map(&Path.relative_to(&1, @elixir_root))
  end

  defp read(rel), do: File.read!(Path.join(@elixir_root, rel))
end
