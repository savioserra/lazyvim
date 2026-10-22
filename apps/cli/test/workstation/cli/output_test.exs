defmodule Workstation.CLI.OutputTest do
  @moduledoc """
  The status wire builder's shape: the schema token pins the hard-cut
  status envelope's identity and the taxonomy travels verbatim.
  """

  use ExUnit.Case, async: true

  alias Workstation.CLI.Output

  test "the status wire carries the schema token and the taxonomy verbatim" do
    wire =
      Output.status("workstation", "elixir", "~", "linux-x64", [], [:a, :b], %{"agent" => "agent"})

    assert wire["schema"] == Output.status_schema()
    assert wire["taxonomy"] == %{"agent" => "agent"}
    assert wire["graph_order"] == [:a, :b]
  end

  test "the plan wire carries the generation, body, manifest and target states" do
    wire = Output.plan("gen-1", %{"entries" => []}, [%{"name" => ".chezmoiremove"}], %{})

    assert wire["schema"] == Output.plan_schema()
    assert wire["generation"] == "gen-1"
    assert wire["plan"] == %{"entries" => []}
    assert wire["manifest"] == [%{"name" => ".chezmoiremove"}]
    assert wire["target_states"] == %{}
  end
end
