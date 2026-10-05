defmodule Workstation.Core.PipelineTest do
  @moduledoc """
  Unit cases for the core pipeline seams the golden replay exercises only
  through its happy path: policy tombstone stability, graph rejection
  guarantees and the canonical-encoding failure modes that keep generation
  ids byte-stable across processes.
  """

  use ExUnit.Case, async: true

  describe "Workstation.Core.Policy" do
    test "legacy removals are the exact seventeen engine tombstones, in policy order" do
      removals = Workstation.Core.Policy.legacy_removals()
      # 17 is the frozen tombstone inventory; a different count means the
      # engine's removal set changed and the manifest digest — and goldens —
      # drift with it.
      assert length(removals) == 17
      # Order is load-bearing: .chezmoiremove bytes are digested into the
      # manifest, so a reorder silently changes every generation id.
      assert removals == Enum.dedup(removals)
      assert hd(removals) == ".local/share/lazyvim"
      assert List.last(removals) == ".local/share/workstation/versions.json"
    end

    test "remove_file deduplicates additions against policy in order" do
      body = Workstation.Core.Policy.remove_file([".local/share/lazyvim", ".config/app/extra"])
      lines = String.split(body, "\n", trim: true)
      assert List.last(lines) == ".config/app/extra"
      assert Enum.frequencies(lines)[".local/share/lazyvim"] == 1
      assert String.ends_with?(body, "\n")
    end

    test "remove_file rejects invalid entries instead of publishing them" do
      assert_raise ArgumentError, ~r/invalid removal entry/, fn ->
        Workstation.Core.Policy.remove_file([""])
      end
    end
  end

  describe "Workstation.Core.Graph" do
    defp spec(id, opts \\ []) do
      %{
        id: id,
        requires: Keyword.get(opts, :requires, []),
        supported_hosts: Keyword.get(opts, :supported_hosts),
        contributes: []
      }
    end

    test "orders dependencies before dependents and keeps declaration order for ties" do
      graph =
        Workstation.Core.Graph.order(%{
          host: "linux",
          specifications: [spec("b", requires: ["a"]), spec("a"), spec("c", requires: ["a"])]
        })

      assert Enum.map(graph.ordered, & &1.id) == ["a", "b", "c"]
    end

    test "rejects unknown dependencies and cycles instead of resolving partially" do
      assert_raise ArgumentError, ~r/unknown capability/, fn ->
        Workstation.Core.Graph.order(%{host: "linux", specifications: [spec("a", requires: ["ghost"])]})
      end

      assert_raise ArgumentError, ~r/cycle/, fn ->
        Workstation.Core.Graph.order(%{
          host: "linux",
          specifications: [spec("a", requires: ["b"]), spec("b", requires: ["a"])]
        })
      end
    end

    test "excludes specs unsupported on the resolved host" do
      graph =
        Workstation.Core.Graph.order(%{
          host: "linux",
          specifications: [spec("mac-only", supported_hosts: %{"darwin" => true}), spec("a")]
        })

      assert graph.ordered |> Enum.map(& &1.id) == ["a"]
      assert graph.enabled == %{"mac-only" => false, "a" => true}
    end
  end

  describe "Workstation.Core.CanonicalJSON" do
    test "encodes object keys sorted, arrays in order and empty maps as arrays" do
      assert Workstation.Core.CanonicalJSON.encode(%{"b" => 1, "a" => 2}) == ~s({"a":2,"b":1})
      assert Workstation.Core.CanonicalJSON.encode([2, 1]) == "[2,1]"
      # A Lua table with no entries is an array to vim.json.encode, so an
      # empty map must encode as [] for byte parity with the recorded goldens.
      assert Workstation.Core.CanonicalJSON.encode(%{}) == "[]"
    end

    test "passes non-ASCII through and fails closed on engine-impossible values" do
      assert Workstation.Core.CanonicalJSON.encode(%{"k" => "é"}) == ~s({"k":"é"})

      assert_raise ArgumentError, ~r/cannot encode nil/, fn ->
        Workstation.Core.CanonicalJSON.encode(%{"k" => nil})
      end
    end
  end
end
