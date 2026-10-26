defmodule Workstation.CLI.OutputTest do
  @moduledoc """
  The read plane's wire builders: the schema tokens pin the hard-cut
  envelopes' identity and the report data travels verbatim.
  """

  use ExUnit.Case, async: true

  alias Workstation.CLI.Output

  @report %{
    "counts" => %{"capabilities" => 1, "claimTargets" => 0, "fileTargets" => 1, "fragments" => 0, "retire" => 0},
    "capabilityOrder" => ["editor"],
    "accounting" => [
      %{
        "id" => "editor",
        "foundation" => "editor",
        "fileTargets" => [".local/bin/nvim"],
        "claimTargets" => [],
        "fragments" => [],
        "retire" => []
      }
    ],
    "fileTargetNames" => [".local/bin/nvim"],
    "claimTargets" => [],
    "fragmentOrder" => []
  }

  # The plan generation is the report's content address, so the reader's
  # cache carries the fixture bytes.
  setup do
    Workstation.Core.Report.put(Jason.encode!(@report))
    on_exit(&Workstation.Core.Report.clear/0)
    :ok
  end

  test "the status wire carries the schema token and the report rows verbatim" do
    wire = Output.status("~", @report)

    assert wire["schema"] == Output.status_schema()
    assert wire["engine"]["mode"] == "report"
    assert wire["capabilityOrder"] == ["editor"]
    assert wire["capabilities"] == @report["accounting"]
    assert wire["counts"] == @report["counts"]
  end

  test "the plan wire carries the generation, the declared surface and the target states" do
    wire = Output.plan("~", @report)

    assert wire["schema"] == Output.plan_schema()
    assert wire["generation"] == Workstation.Core.Report.digest()
    assert wire["declared"]["fileTargets"] == [".local/bin/nvim"]
    assert is_map(wire["target_states"])
  end
end
