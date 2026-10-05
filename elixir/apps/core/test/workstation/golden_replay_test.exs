defmodule Workstation.Core.GoldenReplayTest do
  @moduledoc """
  The Elixir golden replay contract: every `tests/goldens/<profile>/input.json`
  replays through the pure core pipeline (Catalog -> Graph -> Source.plan) and
  must reproduce the recorded bytes exactly — `expected/plan.json`,
  `expected/manifest.json` and `expected/generation.txt`.

  The goldens are recorded by the generator (`Workstation.Core.Golden`, the
  only generator since the c5 lane retired the Lua `golden.lua`) and are
  immutable fixtures: if the replayed output drifts, the engine
  is wrong and must be fixed here — never the goldens. The projection lives
  in `Workstation.Core.Golden.project_plan/2` (a byte-parity port of
  `golden.lua M.project_plan`), shared by generator and replay so the
  recorded and replayed views can never diverge: plan.json is the recorded
  normalized view of the plan, not the plan struct itself, so nil entry
  fields are dropped (a missing Lua key), an explicit JSON null is `:null`,
  and empty maps encode as `[]` exactly like an empty Lua table.
  """

  use ExUnit.Case, async: true

  @goldens_root Path.expand("../../../../../tests/goldens", __DIR__)
  # Compile-time fixture inventory: an unreadable or missing goldens directory
  # is a build-environment error, not a passing empty suite.
  @golden_profiles @goldens_root
                   |> File.ls!()
                   |> Enum.reject(&String.starts_with?(&1, "."))
                   |> Enum.sort()

  describe "golden replay" do
    for profile <- @golden_profiles do
      @profile profile
      @tag :golden
      test "#{profile} reproduces the recorded plan bytes" do
        dir = Path.join(@goldens_root, @profile)
        input = read_json(Path.join([dir, "input.json"]))

        catalog = Workstation.Core.Catalog.load(input)

        graph =
          Workstation.Core.Graph.order(%{
            host: catalog.host,
            specifications: catalog.packages
          })

        plan = Workstation.Core.Source.plan(%{graph: graph})

        # Byte-identical equality: the recorded JSON is the contract, so the
        # comparison is over encoded bytes, never over decoded shapes where a
        # Lua empty table ([]) and an Elixir empty map could diverge.
        assert Workstation.Core.Golden.project_plan(catalog, plan)
               |> Workstation.Core.CanonicalJSON.encode() ==
                 File.read!(Path.join([dir, "expected", "plan.json"]))

        assert Workstation.Core.CanonicalJSON.encode(plan.manifest) ==
                 File.read!(Path.join([dir, "expected", "manifest.json"]))

        assert plan.generation <> "\n" ==
                 File.read!(Path.join([dir, "expected", "generation.txt"]))
      end
    end

    test "every recorded profile is replayed" do
      recorded =
        @goldens_root
        |> File.ls!()
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.sort()

      # Literal names, not a second tree enumeration: comparing the runtime
      # listing against the compile-time one only catches mutation between
      # compile and test. These six names are the golden contract itself; a
      # deleted or newly added golden directory must fail this assertion.
      assert recorded == [
               "conflicts",
               "full-home",
               "minimal",
               "nvim-profile",
               "shell-order",
               "theme"
             ]
    end
  end

  # --- projection lives in Workstation.Core.Golden (shared with the
  # canonical generator; see the moduledoc) ---

  defp read_json(path) do
    contents = File.read!(path)
    {:ok, decoded} = JSON.decode(contents)
    decoded
  end
end
