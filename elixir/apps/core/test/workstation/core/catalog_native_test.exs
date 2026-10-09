defmodule Workstation.Core.CatalogNativeTest do
  @moduledoc """
  Equivalence anchor for the native catalog. The committed golden envelope
  tests/goldens/full-home/input.json is the frozen recording of the complete
  catalog (the complete Lua-era factory output, re-recordable via
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

  @native_count 15

  @goldens_root Path.expand("../../../../../../tests/goldens", __DIR__)

  test "the native catalog equals the recorded complete full-home envelope" do
    input =
      @goldens_root
      |> Path.join("full-home/input.json")
      |> File.read!()
      |> EngineState.decode_json()
      |> case do
        {:ok, input} -> input
        {:error, reason} -> raise("committed golden input.json is undecodable: #{inspect(reason)}")
      end

    recorded = Catalog.load(input)

    # Sanity: the recording really is the complete catalog — otherwise the
    # equality below would pass vacuously.
    assert length(recorded.packages) == @native_count

    native = Catalog.native(host: recorded.host, home: Catalog.canonical_home())

    # The declared foundation layer (lane fusion-final-r2 taxonomy) is
    # status-wire metadata: it lives in the native declarations but outside
    # the frozen envelope contract, so the identity anchor compares the
    # envelope shape exactly and strips the declaration from both sides.
    strip_taxonomy = fn packages -> Enum.map(packages, &Map.delete(&1, :foundation)) end

    assert strip_taxonomy.(native.packages) == strip_taxonomy.(recorded.packages)

    # Asset bodies: the native filesystem reads must equal the recorded
    # inlined bytes for every asset key.
    assert native.assets == recorded.assets
  end

  test "composition resolves the complete native graph without any stub" do
    graph = Catalog.compose(host: "linux")

    # Post-order DFS over the id-sorted specs: dependencies first, ties by
    # id sort — theme and agent land before their dependents, typescript
    # (the last id) stays last.
    assert Enum.map(graph.ordered, & &1.id) == [
             "foundation",
             "node",
             "theme",
             "agent",
             "go",
             "nvim",
             "elixir",
             "fonts",
             "herdr",
             "herdr-pi",
             "pi-ntfy-notifier",
             "pi-skills",
             "secrets",
             "tmux",
             "typescript"
           ]

    assert graph.enabled["theme"] and graph.enabled["tmux"]
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

    # On an unsupportable host the theme closure is excluded, so every
    # HOME-writing dependent fails closed on its disabled dependency.
    assert_raise ArgumentError, ~r/agent requires unsupported capability theme/, fn ->
      Catalog.compose(host: "windows")
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

  test "the live envelope keeps the recorded recipes but re-roots home-anchored destinations" do
    live_home = "/tmp/ws-native-live-home"
    live = Catalog.live(live_home)

    assert live.profile == "live"
    assert live.host == Catalog.native_host()
    assert length(live.packages) == @native_count

    # The one home-anchored SYMLINK destination (the nvim launcher symlink)
    # moved from the canonical recording home to the evaluated home;
    # everything else is byte-identical to the native declarations. The
    # finder keys on ABSOLUTE destinations: within-package links are
    # relative by design and never re-root.
    launcher =
      Enum.flat_map(live.packages, & &1.contributes)
      |> Enum.find(fn
        %{spec: %Workstation.Backends.Chezmoi{kind: :symlink, to: to}} when is_binary(to) ->
          String.starts_with?(to, "/")

        _ ->
          false
      end)

    assert %{spec: %Workstation.Backends.Chezmoi{to: to}} = launcher
    assert to == Path.join(live_home, ".local/opt/nvim/bin/nvim")
    refute String.starts_with?(to, Catalog.canonical_home())
  end

  describe "catalog taxonomy" do
    # The taxonomy is descriptive metadata (status wire only): every package
    # declares the foundation layer it belongs to, the layer set is closed,
    # and the declaration never reaches envelopes or plan bytes.
    test "every package declares a known foundation layer" do
      taxonomy = Packages.taxonomy()

      assert map_size(taxonomy) == length(Packages.modules())

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
      taxonomy = Packages.taxonomy()

      assert taxonomy["nvim"] == "foundation/editor"
      assert taxonomy["tmux"] == "foundation/terminal"
      assert taxonomy["theme"] == "foundation/theme"
      assert taxonomy["fonts"] == "foundation/fonts"
      assert taxonomy["secrets"] == "foundation/secrets"
      assert taxonomy["foundation"] == "foundation/base"

      for agent <- ~w(agent herdr herdr-pi pi-skills pi-ntfy-notifier) do
        assert taxonomy[agent] == "foundation/agent"
      end

      for runtime <- ~w(node go elixir typescript) do
        assert taxonomy[runtime] == "foundation/runtime"
      end
    end
  end
end
