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
  # cannot pass silently. Shrinks with the absorption chain as each
  # capability's manifest leaves (agent + herdr, editor + go + typescript,
  # then tmux: 8).
  @native_count 8

  @goldens_root Path.expand("../../../../../tests/goldens", __DIR__)

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
    # id sort — elixir (requires empty after the editor went native in
    # stage one) leads, theme lands inside nunchux's requires closure,
    # prompt (foundation-only) sorts between nunchux and secrets, secrets
    # (the last id) stays last. The agent, editor and terminal domains'
    # manifests left in the absorption chain's first stage (the native
    # modules/{agent,editor,languages,terminal} modules own those surfaces
    # now).
    assert Enum.map(graph.ordered, & &1.id) == [
             "elixir",
             "foundation",
             "fonts",
             "node",
             "theme",
             "nunchux",
             "prompt",
             "secrets"
           ]

    assert graph.enabled["theme"] and graph.enabled["nunchux"]
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
      taxonomy = Packages.taxonomy()

      assert taxonomy["theme"] == "foundation/theme"
      assert taxonomy["fonts"] == "foundation/fonts"
      assert taxonomy["secrets"] == "foundation/secrets"
      assert taxonomy["foundation"] == "foundation/base"

      # the agent, editor and terminal domains' manifests retired in the
      # absorption chain's first stage (modules/{agent,editor,languages,
      # terminal} own those surfaces natively)

      for runtime <- ~w(node elixir) do
        assert taxonomy[runtime] == "foundation/runtime"
      end
    end
  end
end
