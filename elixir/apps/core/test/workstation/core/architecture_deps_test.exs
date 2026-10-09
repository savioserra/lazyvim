defmodule Workstation.Core.ArchitectureDepsTest do
  @moduledoc """
  Zero-attraction dependency guards (source scans as ExUnit).

  Three invariants, enforced so they can never regrow. The scanners are the
  shared primitives in `Workstation.Core.ArchitectureLaw` (test support);
  `Workstation.Core.LayerLawTest` self-tests those primitives against
  planted violating fixtures, so the scans are proven able to fail and not
  merely passing tautologically.

    1. **The theme capability is a GENERIC engine.** Its engine modules
       (`Workstation.Core.Theme`, `Workstation.Core.Theme.Tokens`, the CLI
       and daemon theme resolvers) must never name a concrete consumer
       package. Consumers derive from the theme contract in their own
       catalog package modules (`catalog/packages/**`), which the engine
       discovers through the `Workstation.Core.Contracts.Provider` contract.

    2. **Generic core names no consumer and no backend encoding.** Domain
       modules must not reference concrete consumer packages nor the
       chezmoi target-name encoding (`dot_` mapping, `_tmpl` suffixing,
       the reserved prefix family).

    3. **Backend isolation.** The chezmoi backend is referenced exclusively
       through its module API (`provider_id/0`, `data_provider_id/0`,
       `remove_filename/0`, `data_filename/0`, and `@chezmoi`-style
       compile-time attributes bound to them) — a raw "chezmoi" mention in
       code fails.

  ## Exemption table (kept in sync with @core_exempts below — each entry
  ## states why the exemption is irreducible)

  | file | why exempt |
  |------|------------|
  | `source/chezmoi.ex` | the backend module itself — it OWNS the dialect |
  | `provisioner.ex` | backend execution bridge (runs the pinned argv) |
  | `shell_program.ex` | composes the backend modify-program |
  | `update/bootstrap.ex` | installs and integrity-verifies the backend BINARY itself — naming the backend is the job; irreducible |
  | `policy.ex` | deploy-path tombstones are policy data about the PAST: a retired path (`.config/nvim/...`, `.pi/agent/...`) must be named verbatim or it cannot be retired; irreducible |
  | `golden.ex` | fixture oracle: the recorded envelopes pin the wire provider ids (e.g. `nvim-profile` as profile fixture id); the oracle is load-bearing on those literals; irreducible without regenerating oracle data for zero law value |

  The consumer layer itself (`catalog/**`, including `catalog.ex`, the
  registry composition point) is scanned only for encoding/backend tokens,
  never for consumer names: naming consumers is the layer's job.
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

  # Files exempt from the core-wide scans. KEEP THE @moduledoc TABLE ABOVE
  # IN SYNC — every entry carries its irreducibility justification there.
  @core_exempts %{
    "apps/core/lib/workstation/backends/chezmoi.ex" => "the backend module itself",
    "apps/core/lib/workstation/core/provisioner.ex" => "backend execution bridge",
    "apps/core/lib/workstation/core/shell_program.ex" => "backend modify-program composer",
    "apps/core/lib/workstation/core/update/bootstrap.ex" => "installs and verifies the backend binary itself",
    "apps/core/lib/workstation/core/policy.ex" => "deploy-path tombstones are policy data about the past (paths named verbatim)",
    "apps/core/lib/workstation/core/golden.ex" => "fixture oracle pins the recorded envelopes' wire provider ids"
  }

  describe "theme engine purity" do
    test "theme engine modules never name a concrete consumer package" do
      for rel <- @theme_engine_files do
        source = read(rel)

        violations = consumer_violations(source)

        assert violations == [],
               "#{rel} references consumer packages #{inspect(violations)} — " <>
                 "consumers must derive from the theme contract in their own package module"
      end
    end
  end

  describe "core domain purity" do
    test "generic core code never names a consumer package or the backend encoding" do
      for rel <- core_files(), not Map.has_key?(@core_exempts, rel), not catalog_consumer?(rel) do
        code = code_lines(read(rel))

        consumer_hits = consumer_violations(code)
        encoding_hits = encoding_violations(code)

        assert consumer_hits == [],
               "#{rel} names consumer packages #{inspect(consumer_hits)} — " <>
                 "the dependency must point consumer -> contract, never domain -> consumer"

        assert encoding_hits == [],
               "#{rel} contains backend encoding tokens #{inspect(encoding_hits)} — " <>
                 "target-name encoding lives only in Workstation.Backends.Chezmoi"
      end
    end

    test "generic core code references the backend only through its module API" do
      for rel <- core_files(),
          not Map.has_key?(@core_exempts, rel),
          not catalog_consumer?(rel),
          not String.contains?(rel, "backends/chezmoi") do
        violations = backend_literal_violations(read(rel))

        assert violations == [],
               "#{rel} #{inspect(violations)} — reference the backend through " <>
                 "Workstation.Backends.Chezmoi (provider ids, engine file constants)"
      end
    end
  end

  # The scan set is the Workstation.Core namespace itself: kernel machinery,
  # platforms and the catalog registry. Package spec modules live under
  # Workstation.Packages (the consumer layer) — consumers derive from
  # contracts and are not part of core, so they are not scanned here.
  defp core_files do
    Path.wildcard(Path.join(@elixir_root, "apps/core/lib/workstation/core/**/*.ex"))
    |> Enum.map(&Path.relative_to(&1, @elixir_root))
  end

  defp read(rel), do: File.read!(Path.join(@elixir_root, rel))

  defp catalog_consumer?(rel), do: String.contains?(rel, "catalog/packages")
end
