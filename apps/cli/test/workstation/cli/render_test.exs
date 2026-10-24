defmodule Workstation.CLI.RenderTest do
  @moduledoc """
  The plain-text layout contract for the hard-cut core wires. The layout is
  user-facing (stable under redirection), so the lines themselves are pinned
  exactly: the declared-inventory line, the capability rollup, the fragment
  and retire lines, and the padded per-target state column.
  """

  use ExUnit.Case, async: true

  alias Workstation.CLI.Render

  defp lines(text), do: String.split(text, "\n")

  # --- status -----------------------------------------------------------------

  test "core_status renders the engine block and the declared inventory" do
    rendered =
      lines(
        Render.core_status(%{
          "engine" => %{"name" => "workstation", "version" => "0.1.0", "mode" => "report"},
          "destination" => "~",
          "platform" => "linux",
          "counts" => %{"capabilities" => 2, "fileTargets" => 29, "claimTargets" => 2, "fragments" => 12, "retire" => 2},
          "capabilityOrder" => ["editor", "terminal"]
        })
      )

    assert "  engine     : workstation 0.1.0 (mode: report)" in rendered
    assert "  declared   : 29 file targets · 2 tree claims · 12 fragments · 2 retire" in rendered
    assert "  capabilities (2): editor, terminal" in rendered
  end

  # --- plan -------------------------------------------------------------------

  defp plan_wire do
    %{
      "generation" => String.duplicate("a", 64),
      "declared" => %{
        "fileTargets" => [".config/rc"],
        "claimTargets" => [".config/nvim"],
        "retire" => [".config/old"],
        "fragmentOrder" => [%{"target" => ".zshrc", "fragments" => ["a", "b"]}]
      },
      "target_states" => %{".config/old" => "file 100644"}
    }
  end

  test "core_plan renders the declared counts and the fragment lane" do
    rendered = lines(Render.core_plan(plan_wire()))

    assert "  declared   : 1 file targets · 1 tree claims" in rendered
    assert "  fragments  : 2 on 1 rc targets" in rendered
    assert "  retire     : 1 (.config/old)" in rendered
  end

  test "core_plan marks retire targets and pins the state column" do
    rendered = lines(Render.core_plan(plan_wire()))

    # The retire tombstone carries the suffix; a probed target renders its
    # live state, an unprobed one "?".
    assert "  target #{String.pad_trailing(".config/old", 45)} file 100644 (retire)" in rendered
    assert "  target #{String.pad_trailing(".config/rc", 45)} ?" in rendered
  end
end
