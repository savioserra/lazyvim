defmodule Workstation.Core.GraphTest do
  @moduledoc """
  The capability-graph edge contract: `requires` keeps necessity plus
  ordering, `after` is ordering-only (systemd `After=` semantics — applied
  only when the target is present and enabled, no necessity, no pull-in),
  ties resolve by id sort regardless of input order, and cycles are
  rejected with the cycle path in the error.
  """

  use ExUnit.Case, async: true

  defp order(specifications, host \\ "linux") do
    Workstation.Core.Graph.order(%{host: host, specifications: specifications})
  end

  defp spec(id, opts \\ []) do
    %{
      id: id,
      requires: Keyword.get(opts, :requires),
      after: Keyword.get(opts, :after),
      supported_hosts: Keyword.get(opts, :supported_hosts),
      contributes: []
    }
  end

  test "an after edge sequences when both nodes are present and enabled" do
    graph = order([spec("later", after: ["early"]), spec("early")])
    assert Enum.map(graph.ordered, & &1.id) == ["early", "later"]
  end

  test "an after edge does not pull the target in and never fails on absence" do
    graph = order([spec("lonely", after: ["absent"])])
    assert Enum.map(graph.ordered, & &1.id) == ["lonely"]
  end

  test "an after edge to a host-disabled target is skipped without failure" do
    disabled = %{id: "off", requires: nil, supported_hosts: %{"darwin" => true}, contributes: []}
    graph = order([spec("later", after: ["off"]), disabled])
    assert Enum.map(graph.ordered, & &1.id) == ["later"]
  end

  test "requires keeps necessity: a missing dependency is rejected" do
    assert_raise ArgumentError, ~r/lonely requires unknown capability absent/, fn ->
      order([spec("lonely", requires: ["absent"])])
    end
  end

  test "requires keeps necessity: a host-disabled dependency is rejected" do
    disabled = %{id: "off", requires: nil, supported_hosts: %{"darwin" => true}, contributes: []}

    assert_raise ArgumentError, ~r/lonely requires unsupported capability off/, fn ->
      order([spec("lonely", requires: ["off"]), disabled])
    end
  end

  test "dependency-equal specs resolve by id sort, independent of input order" do
    reversed = [spec("c"), spec("b"), spec("a")]
    shuffled = [spec("b"), spec("a"), spec("c")]

    assert Enum.map(order(reversed).ordered, & &1.id) == ["a", "b", "c"]
    assert Enum.map(order(shuffled).ordered, & &1.id) == ["a", "b", "c"]
  end

  test "a cycle through after edges is rejected with the cycle path" do
    assert_raise ArgumentError, ~r/capability dependency cycle at a: a -> b -> a/, fn ->
      order([spec("a", after: ["b"]), spec("b", after: ["a"])])
    end
  end

  test "a cycle through requires edges is rejected with the cycle path" do
    assert_raise ArgumentError, ~r/capability dependency cycle at a: a -> b -> c -> a/, fn ->
      order([spec("a", requires: ["b"]), spec("b", requires: ["c"]), spec("c", requires: ["a"])])
    end
  end

  test "requires and after edges chain into one deterministic order" do
    # base -> middle (requires); later sequences after middle without
    # depending on it; free has no edges and lands by id sort.
    specifications = [
      spec("free"),
      spec("later", after: ["middle"]),
      spec("middle", requires: ["base"]),
      spec("base")
    ]

    assert Enum.map(order(specifications).ordered, & &1.id) == [
             "base",
             "free",
             "middle",
             "later"
           ]
  end

  test "a non-string after edge is a shape error" do
    assert_raise ArgumentError, ~r/bad has a non-string after edge/, fn ->
      order([spec("bad", after: [3])])
    end
  end

  test "duplicate ids are rejected regardless of edge kinds" do
    assert_raise ArgumentError, ~r/duplicate capability: dup/, fn ->
      order([spec("dup"), spec("dup", after: ["dup"])])
    end
  end
end
