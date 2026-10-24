defmodule Workstation.Core.CatalogNativeTest do
  @moduledoc """
  Equivalence anchor for the native catalog. The committed golden envelope
  tests/goldens/full-home/input.json is the frozen recording of the complete
  catalog (re-recordable via
  `mix workstation.goldens`), so the native registry must load to exactly
  the same denormalized catalog: ids, requires, host gates, recipe bytes and
  inlined asset bodies, position for position. Composition runs the real
  native graph with no stub.

  A drift here means a native declaration moved away from the recorded
  envelope: re-record deliberately via `mix workstation.goldens` after
  review — never by editing goldens.
  """

  use ExUnit.Case, async: true

  alias Workstation.Core.Catalog
  alias Workstation.Core.Catalog.Packages
  alias Workstation.Core.EngineState

  # the discovered catalog's size, pinned so an accidental discovery change
  # cannot pass silently. Shrunk to zero with the absorption chain's first
  # stage: every capability manifest retired (elixir, the chain's last, died
  # in its final commit) — the native modules own every surface.
  @native_count 0

  test "composition resolves the complete native graph without any stub" do
    graph = Catalog.compose(host: "linux")

    # Post-order DFS over the id-sorted specs: the last manifest standing
    # (elixir) died in the chain's final commit — the discovered catalog is
    # empty, every surface natively owned by the
    # modules/{agent,editor,foundation,fonts,languages,secrets,terminal,
    # theme} modules.
    assert Enum.map(graph.ordered, & &1.id) == []

    assert graph.enabled == %{}
  end

  test "composition keeps graph rejection semantics through the catalog seam" do
    assert_raise ArgumentError, ~r/cycle/, fn ->
      Catalog.compose(
        host: "linux",
        specifications: [
          %{id: "a", requires: ["b"], supported_hosts: nil, contributes: []},
          %{id: "b", requires: ["a"], supported_hosts: nil, contributes: []}
        ]
      )
    end

    # On an unsupportable host the theme closure is excluded before its
    # dependents' requires are checked: theme, tmux and nunchux all gate
    # themselves to linux/darwin — composition succeeds without the closure.
    windows = Catalog.compose(host: "windows")

    refute windows.enabled["theme"]
    refute windows.enabled["tmux"]
    refute windows.enabled["nunchux"]
    ordered_ids = Enum.map(windows.ordered, & &1.id)
    refute "theme" in ordered_ids

    # A supported dependent on an excluded capability still fails closed
    # through the same seam (the native catalog has no such shape left —
    # the synthetic set mirrors the cycle case above).
    assert_raise ArgumentError, ~r/consumer requires unsupported capability theme/, fn ->
      Catalog.compose(
        host: "windows",
        specifications: [
          %{id: "consumer", requires: ["theme"], supported_hosts: nil, contributes: []},
          %{id: "theme", requires: [], supported_hosts: %{"linux" => true}, contributes: []}
        ]
      )
    end
  end

  describe "recorded envelope edge contract" do
    # A minimal decoded input.json envelope: the shape the golden
    # generator records and Catalog.load denormalizes.
    defp envelope(packages, home \\ "/home/golden") do
      %{
        "profile" => "envelope-edge",
        "host" => "linux",
        "home" => home,
        "packages" => packages,
        "data" => %{},
        "remove_file" => []
      }
    end

    test "a recorded after edge survives load and sequences composition" do
      catalog =
        envelope([
          %{
            "id" => "b",
            "requires" => [],
            "after" => ["a"],
            "contributes" => []
          },
          %{"id" => "a", "requires" => [], "contributes" => []}
        ])
        |> Catalog.load()

      # Nil-drop convention: an empty/absent after list keeps the loaded
      # package byte-shape equal to the native spec (no :after key).
      assert Map.has_key?(Enum.find(catalog.packages, &(&1.id == "a")), :after) == false
      assert Enum.find(catalog.packages, &(&1.id == "b")).after == ["a"]

      graph = Catalog.compose(host: "linux", specifications: catalog.packages)
      assert Enum.map(graph.ordered, & &1.id) == ["a", "b"]
    end

    test "a recorded integer ordering field is rejected with the ban message" do
      assert_raise ArgumentError, ~r/integer ordering fields are banned/, fn ->
        envelope([
          %{"id" => "a", "requires" => [], "order" => 3, "contributes" => []}
        ])
        |> Catalog.load()
      end
    end
  end

  test "asset resolution fails closed on a package the checkout does not carry" do
    # The engine root here is the real dev checkout; the PACKAGE is the
    # missing piece, so no environment or checkout surgery is needed and the
    # assertion stays race-free under async suites. Production triggers the
    # same fail-closed raise when the checkout is incomplete (the CLI maps
    # it to the engine-failure exit).
    assert_raise ArgumentError, ~r/native catalog asset is missing or empty/, fn ->
      Catalog.package_asset!("ghost", "files/absent")
    end
  end

  test "the live envelope carries no home-anchored destinations left to re-root" do
    # The re-rooting law's one fixture — the nvim launcher's absolute
    # /home/golden symlink — retired with the nvim manifest in the
    # absorption chain's first stage. No manifest carries an absolute
    # destination anymore; when one ever reappears, this is the seam that
    # must re-root it to the evaluated home.
    live = Catalog.live("/tmp/ws-native-live-home")

    refute Enum.any?(Enum.flat_map(live.packages, & &1.contributes), fn
           %{spec: %Workstation.Backends.Chezmoi{kind: :symlink, to: to}} when is_binary(to) ->
             String.starts_with?(to, "/")

           _ ->
             false
         end)
  end

  describe "catalog taxonomy" do
    # The taxonomy is descriptive metadata (status wire only): every package
    # declares the foundation layer it belongs to, the layer set is closed,
    # and the declaration never reaches envelopes or plan bytes.
    test "every package declares a known foundation layer" do
      taxonomy = Packages.taxonomy()

      assert map_size(taxonomy) == length(Packages.packages())

      for {id, foundation} <- taxonomy do
        assert foundation in ~w(
                 foundation/base
                 foundation/editor
                 foundation/runtime
                 foundation/terminal
                 foundation/agent
                 foundation/theme
                 foundation/fonts
                 foundation/secrets
               ), "#{id}: unknown foundation #{foundation}"
      end
    end

    test "the owner-declared anchors hold" do
      # every domain's manifest retired in the absorption chain's first
      # stage (modules/{agent,editor,foundation,fonts,languages,secrets,
      # terminal,theme} own those surfaces natively) — the taxonomy is
      # empty with the catalog
      assert Packages.taxonomy() == %{}
    end
  end
end
