defmodule Workstation.CLI.OutputTest do
  @moduledoc """
  The status wire builder's journal shape: `nil` journal emits the explicit
  `:null` token the status schema reserves for "never applied", while an
  applied journal carries `at` only when present — the canonical-JSON rule
  says optional fields are OMITTED, never emitted as nulls.
  """

  use ExUnit.Case, async: true

  alias Workstation.CLI.Output

  defp status(journal) do
    Output.status("workstation", "elixir", "~", "linux-x64", [], [], journal, %{})
  end

  test "an absent journal is the explicit null token, never a dropped key" do
    wire = status(nil)

    assert wire["schema"] == Output.status_schema()
    assert wire["journal"] == :null
  end

  test "a journal with an at stamp carries it on the wire" do
    wire = status(%{"generation" => "g1", "revision" => 2, "at" => 1_700_000_000})

    assert wire["journal"] == %{"generation" => "g1", "revision" => 2, "at" => 1_700_000_000}
  end

  test "a journal without an at stamp omits the field instead of emitting null" do
    wire = status(%{"generation" => "g1", "revision" => 2, "at" => nil})

    assert wire["journal"] == %{"generation" => "g1", "revision" => 2}
    refute Map.has_key?(wire["journal"], "at")
  end
end
