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
    assert native.packages == recorded.packages

    # Asset bodies: the native filesystem reads must equal the recorded
    # inlined bytes for every asset key.
    assert native.assets == recorded.assets
  end

  test "composition resolves the complete native graph without any stub" do
    graph = Catalog.compose(host: "linux")

    # Post-order DFS over the declaration order: dependencies first, ties in
    # catalog order — theme and agent land before their dependents, tmux
    # stays last.
    assert Enum.map(graph.ordered, & &1.id) == [
             "foundation",
             "fonts",
             "node",
             "theme",
             "agent",
             "pi-skills",
             "pi-ntfy-notifier",
             "go",
             "herdr",
             "herdr-pi",
             "secrets",
             "nvim",
             "typescript",
             "elixir",
             "tmux"
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
        %{spec: %Workstation.Core.Source.Chezmoi{kind: :symlink, to: to}} when is_binary(to) ->
          String.starts_with?(to, "/")

        _ ->
          false
      end)

    assert %{spec: %Workstation.Core.Source.Chezmoi{to: to}} = launcher
    assert to == Path.join(live_home, ".local/opt/nvim/bin/nvim")
    refute String.starts_with?(to, Catalog.canonical_home())
  end
end
