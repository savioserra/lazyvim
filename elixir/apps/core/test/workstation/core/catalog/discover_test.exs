defmodule Workstation.Core.Catalog.DiscoverTest do
  @moduledoc """
  The discovery contract: providers come from `:code.all_available/0` +
  behaviour conformance in the `Workstation.Core.Catalog.Packages.*`
  namespace — never a hand-written registration list — with deterministic
  test-tree exclusion, actionable spec-shape rejections, the banned
  integer-ordering rule and duplicate-id rejection.
  """

  use ExUnit.Case, async: true

  alias Workstation.Core.Catalog.{Discover, Packages, Spec}

  @native_modules [
    Workstation.Core.Catalog.Packages.Agent,
    Workstation.Core.Catalog.Packages.ElixirLang,
    Workstation.Core.Catalog.Packages.Fonts,
    Workstation.Core.Catalog.Packages.Foundation,
    Workstation.Core.Catalog.Packages.Go,
    Workstation.Core.Catalog.Packages.Herdr,
    Workstation.Core.Catalog.Packages.HerdrPi,
    Workstation.Core.Catalog.Packages.Node,
    Workstation.Core.Catalog.Packages.Nvim,
    Workstation.Core.Catalog.Packages.PiNtfyNotifier,
    Workstation.Core.Catalog.Packages.PiSkills,
    Workstation.Core.Catalog.Packages.Secrets,
    Workstation.Core.Catalog.Packages.Theme,
    Workstation.Core.Catalog.Packages.Tmux,
    Workstation.Core.Catalog.Packages.Typescript
  ]

  test "discovery finds exactly the native providers, in module-name order" do
    assert Discover.providers() == @native_modules
    assert length(Packages.modules()) == 15

    # Production composition consumes the VALIDATED discovery seam — the
    # spec-shape and duplicate-id rejections apply to the real catalog,
    # not only to direct validate_specs calls.
    assert Packages.packages() == Discover.specs()
    assert length(Packages.packages()) == length(Packages.modules())
  end

  test "discovered specs are the native catalog, id-sorted with no duplicates" do
    specs = Discover.specs()
    assert Enum.map(specs, & &1.id) == Enum.map(specs, & &1.id) |> Enum.sort()
    assert Enum.map(specs, & &1.id) == Enum.map(Packages.packages(), & &1.id)
    assert Enum.uniq_by(specs, & &1.id) == specs
  end

  test "a conforming fixture compiled from test/support is excluded from discovery" do
    # The fixture is a real provider (behaviour + valid spec) that sits in
    # the test build's code path; only the deterministic /test/ source-path
    # exclusion keeps it out of the live catalog.
    {:module, _} = Code.ensure_loaded(Workstation.Core.Catalog.Packages.GhostFixture)
    refute Workstation.Core.Catalog.Packages.GhostFixture in Discover.providers()
    refute Enum.any?(Packages.packages(), &(&1.id == "ghost-fixture"))
  end

  test "duplicate package ids are rejected naming every declaring module" do
    pairs = [
      {Alpha, %{id: "same", requires: [], foundation: "foundation/base", contributes: []}},
      {Beta, %{id: "same", requires: [], foundation: "foundation/base", contributes: []}}
    ]

    assert_raise ArgumentError,
                 ~r/duplicate package id same declared by \[Alpha, Beta\]/,
                 fn ->
                   Discover.validate_specs(pairs)
                 end
  end

  test "spec shape rejections name the offending module and field" do
    bad = [
      {{Broken, :not_a_map}, ~r/Broken \(package spec\): spec\(\) must return a map/},
      {{Broken, %{id: ""}}, ~r/Broken \(package spec\): id must be a non-empty string/},
      {{Broken, %{id: "x"}}, ~r/Broken \(package spec\): foundation must be a non-empty string/},
      {{Broken, %{id: "x", foundation: "f", requires: ["ok", 3]}},
       ~r/Broken \(package spec\): x\.requires must contain only non-empty strings/},
      {{Broken, %{id: "x", foundation: "f", after: [3]}},
       ~r/Broken \(package spec\): x\.after must contain only non-empty strings/},
      {{Broken, %{id: "x", foundation: "f", supported_hosts: %{"linux" => "yes"}}},
       ~r/Broken \(package spec\): x\.supported_hosts must map host names to booleans/},
      {{Broken, %{id: "x", foundation: "f", contributes: "nope"}},
       ~r/Broken \(package spec\): x\.contributes must be a list/}
    ]

    Enum.each(bad, fn {{module, spec}, message} ->
      assert_raise ArgumentError, message, fn -> Spec.validate!(spec, module) end
    end)
  end

  test "integer ordering fields are banned on package specs" do
    Enum.each([:order, :position, :priority], fn key ->
      spec = Map.put(%{id: "x", foundation: "f"}, key, 3)

      assert_raise ArgumentError,
                   ~r/#{key}.*integer ordering fields are banned.*ties resolve by id sort/s,
                   fn ->
                     Spec.validate!(spec, Broken)
                   end

      # The ban is on presence, not on the value's type: any ordering knob
      # reintroduces the hand-coordinated registry.
      assert_raise ArgumentError, ~r/integer ordering fields are banned/, fn ->
        Spec.validate!(Map.put(spec, key, "first"), Broken)
      end
    end)
  end

  test "valid specs pass validation" do
    :ok =
      Spec.validate!(
        %{
          foundation: "foundation/base",
          id: "x",
          requires: ["y"],
          after: ["z"],
          supported_hosts: %{"linux" => true},
          contributes: []
        },
        Broken
      )
  end
end
