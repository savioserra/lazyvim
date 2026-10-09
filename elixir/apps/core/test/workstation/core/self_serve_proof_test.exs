defmodule Workstation.Core.SelfServeProofTest do
  @moduledoc """
  The R3 exit proof: a synthetic test package achieves full self-serve —
  manifest + payloads only, zero engine edits. The package is declared in
  this file (above), composed through the documented `:specifications`
  seam, and driven through the real graph and source plan; the theme
  payload is rendered through the derivation contract's consumer-owned
  adapter. Nothing in `lib/` changes for a new package — that is the exit
  criterion, and this suite is its anchor.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.Catalog
  alias Workstation.Core.Catalog.Discover
  alias Workstation.Core.Catalog.Spec
  alias Workstation.Core.Source

  @manifest Workstation.Packages.HelixSynth.spec()

  test "the manifest is discovery-conformant (the same contract the native packages pass)" do
    assert :ok = Spec.validate!(@manifest, Workstation.Packages.HelixSynth)
  end

  test "production discovery still excludes the synthetic package (zero catalog drift)" do
    refute Workstation.Packages.HelixSynth in Discover.providers()
    refute Enum.any?(Discover.specs(), &(&1.id == "helix-synth"))
  end

  test "compose orders the synthetic package after its declared requires" do
    graph = compose()

    ids = Enum.map(graph.ordered, & &1.id)
    assert ids == ["foundation", "theme", "helix-synth"]
  end

  test "the plan carries the rendered theme payload and the shell fragment" do
    plan = Source.plan(%{graph: compose()})

    theme_entry = Enum.find(plan.entries, &(&1.target == ".config/helix-synth/theme.toml"))
    assert theme_entry != nil
    assert theme_entry.bytes =~ "[theme]"
    assert theme_entry.bytes =~ "# appearance: dark" and theme_entry.bytes =~ "# appearance: light"

    # Theme roles flowed through the derivation adapter: the rendered hexes
    # are the token set's own values (one color truth per layer).
    accent =
      Workstation.Core.Theme.Tokens.palette(:dark)
      |> Enum.find(fn {role, _hex} -> role == :accent end)
      |> elem(1)

    assert theme_entry.bytes =~ accent

    shell_entry = Enum.find(plan.entries, &(&1.target == ".zshrc"))
    assert shell_entry != nil
  end

  test "planning is deterministic: identical declarations, identical generation" do
    plan_a = Source.plan(%{graph: compose()})
    plan_b = Source.plan(%{graph: compose()})

    assert plan_a.generation == plan_b.generation
    assert plan_a.manifest == plan_b.manifest
  end

  defp compose do
    Catalog.compose(
      host: "linux",
      specifications: [
        Workstation.Packages.Foundation.spec(),
        Workstation.Packages.Theme.spec(),
        @manifest
      ]
    )
  end
end
