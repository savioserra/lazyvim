defmodule Workstation.Core.Catalog.DiscoverTest do
  @moduledoc """
  The discovery contract: the catalog comes from the package tree —
  compiled provider modules plus data manifests (`manifest.json`) — never
  a hand-written registration list — with deterministic walking, actionable
  spec-shape rejections, the banned integer-ordering rule and duplicate-id
  rejection across both arms.
  """

  use ExUnit.Case, async: true

  alias Workstation.Core.Catalog.{Discover, Packages, Spec}

  @native_modules [
    Workstation.Packages.Agent,
    Workstation.Packages.ElixirLang,
    Workstation.Packages.Fonts,
    Workstation.Packages.Foundation,
    Workstation.Packages.Go,
    Workstation.Packages.Herdr,
    Workstation.Packages.HerdrPi,
    Workstation.Packages.Node,
    Workstation.Packages.Nvim,
    Workstation.Packages.PiNtfyNotifier,
    Workstation.Packages.PiSkills,
    Workstation.Packages.Secrets,
    Workstation.Packages.Theme,
    Workstation.Packages.Tmux,
    Workstation.Packages.Typescript
  ]

  test "discovery finds exactly the native providers, in module-name order" do
    assert Discover.providers() == @native_modules
    assert length(Packages.modules()) == 15

    # Production composition consumes the VALIDATED discovery seam — the
    # spec-shape and duplicate-id rejections apply to the real catalog,
    # not only to direct validate_specs calls. The data-manifest arm serves
    # nunchux, so the catalog stays the complete set while the module count
    # reflects only the compiled arm.
    assert Packages.packages() == Discover.specs()
    assert length(Packages.packages()) == 16
  end

  test "the data-manifest arm serves nunchux without a compiled module" do
    # The manifest is JSON data beside the payloads; no
    # Workstation.Packages.Nunchux module exists, discovery still serves
    # the package, and the denormalized spec shape is exactly a compiled
    # provider's.
    assert {:error, _reason} = Code.ensure_loaded(Workstation.Packages.Nunchux)

    spec = Enum.find(Discover.specs(), &(&1.id == "nunchux"))
    assert spec.foundation == "foundation/terminal"
    assert Enum.map(spec.contributes, & &1.provider) == ["git", "chezmoi", "chezmoi"]
  end

  test "discovered specs are the native catalog, id-sorted with no duplicates" do
    specs = Discover.specs()
    assert Enum.map(specs, & &1.id) == Enum.map(specs, & &1.id) |> Enum.sort()
    assert Enum.map(specs, & &1.id) == Enum.map(Packages.packages(), & &1.id)
    assert Enum.uniq_by(specs, & &1.id) == specs
  end

  test "a conforming fixture compiled from test/support is excluded from discovery" do
    # The fixture is a real provider (behaviour + valid spec) that sits in
    # the test build's code path; only the deterministic test-tree source
    # exclusion keeps it out of the live catalog.
    {:module, _} = Code.ensure_loaded(Workstation.Packages.GhostFixture)
    refute Workstation.Packages.GhostFixture in Discover.providers()
    refute Enum.any?(Packages.packages(), &(&1.id == "ghost-fixture"))
  end

  test "a relative recorded test path is excluded by segment semantics, not substring" do
    # A "/test/" substring check missed beams whose compile_info recorded a
    # RELATIVE source path ("test/support/…" carries no leading slash);
    # exclusion keys on the `test` path segment being an ancestor of the
    # recorded source file.
    source = "test/support/workstation/core/catalog/packages/relative_probe.ex"

    [{_module, beam}] =
      Code.compile_string(
        ~s(defmodule Workstation.Core.Catalog.Packages.RelativeProbe do
             @behaviour Workstation.Core.Catalog.Spec

             @impl true
             def spec, do: %{id: "relative-probe", foundation: "foundation/base", contributes: []}
           end),
        source
      )

    dir = Path.join(System.tmp_dir!(), "discover-probe-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    beam_path = Path.join(dir, "Elixir.Workstation.Core.Catalog.Packages.RelativeProbe.beam")
    File.write!(beam_path, beam)

    on_exit(fn ->
      File.rm(beam_path)
      File.rmdir(dir)
      :code.purge(Workstation.Core.Catalog.Packages.RelativeProbe)
    end)

    assert Code.prepend_path(dir)

    # compile_string loaded the module from memory, and the code server
    # caches the negative :code.which lookup — purge AND delete so
    # discovery resolves — and reads — the tmp beam with its recorded
    # relative test path.
    mod = Workstation.Core.Catalog.Packages.RelativeProbe
    :code.purge(mod)
    :code.delete(mod)

    # Conforms on every axis (namespace, behaviour, spec/0, valid spec) —
    # only the recorded relative test path excludes it.
    refute Workstation.Core.Catalog.Packages.RelativeProbe in Discover.providers()
    refute Enum.any?(Packages.packages(), &(&1.id == "relative-probe"))
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
