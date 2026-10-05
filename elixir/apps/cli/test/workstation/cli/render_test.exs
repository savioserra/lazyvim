defmodule Workstation.CLI.RenderTest do
  @moduledoc """
  The plain-text layout contract for the hard-cut core wires. The layout is
  user-facing (stable under redirection, mirrored by parity anchors), so the
  lines themselves are pinned exactly: count and baseline lines, the
  unsupported-reversal section, removal suffixes, and patch bodies printed
  verbatim.
  """

  use ExUnit.Case, async: true

  alias Workstation.CLI.Render

  defp lines(text), do: String.split(text, "\n")

  # --- status -----------------------------------------------------------------

  test "core_status renders the packages line and both journal shapes" do
    empty = Render.core_status(%{"platform" => "linux-x64", "packages" => [], "journal" => nil})
    assert "packages: none" in lines(empty)
    assert "journal: none" in lines(empty)

    two =
      Render.core_status(%{
        "platform" => "linux-x64",
        "packages" => [%{"id" => "a"}, %{"id" => "b"}],
        "journal" => nil
      })

    assert "packages: a, b" in lines(two)

    journaled =
      Render.core_status(%{
        "platform" => "linux-x64",
        "packages" => [],
        "journal" => %{"generation" => "g1", "revision" => 2, "at" => 1_700_000_000}
      })

    assert "journal: generation=g1 revision=2 at=1700000000" in lines(journaled)
  end

  # --- plan ---------------------------------------------------------------------

  defp plan_wire do
    %{
      "generation" => "gen-1",
      "plan" => %{
        "entries" => [
          %{
            "operation" => "create",
            "name" => "rc",
            "target" => ".config/rc",
            "type" => "file",
            "mode" => "600",
            "owner" => "tooling"
          }
        ],
        "removals" => [%{"target" => ".config/old", "owner" => "legacy"}],
        "unsupported_reversals" => [%{"target" => ".config/site", "owner" => "admin"}],
        "baseline_generation" => "abc123"
      },
      "patches" => [
        %{
          "kind" => "change",
          "source" => "dot_config/rc",
          "diff" => "--- a/dot_config/rc\n+++ b/dot_config/rc\n@@ -1 +1 @@\n-old\n+new\n"
        },
        %{"kind" => "delete", "source" => "dot_config/gone", "owner" => "legacy"}
      ],
      "target_states" => %{}
    }
  end

  test "core_plan renders count, baseline and unsupported-reversal lines" do
    rendered = lines(Render.core_plan(plan_wire()))

    assert "  entries    : 1  removals: 1" in rendered
    assert "  baseline   : abc123 (verified against the journaled manifest)" in rendered
    assert "  unsupported reversals (arbitrary whole-body modifiers; clean up explicitly):" in rendered
    assert "    .config/site (was owned by admin)" in rendered
  end

  test "core_plan marks removal targets and prints patch bodies verbatim" do
    rendered = lines(Render.core_plan(plan_wire()))

    # Removal targets carry the suffix; state column is "?" for unprobed targets.
    assert "  target #{String.pad_trailing(".config/old", 45)} ? (removal)" in rendered

    # A raw diff is the verbatim body (trimmed of its trailing newline only);
    # a patch without a diff prints its attributed header instead.
    assert "--- a/dot_config/rc" in rendered
    assert "+new" in rendered
    assert "# delete dot_config/gone (, owner legacy)" in rendered
  end

  # --- diff ---------------------------------------------------------------------

  test "core_diff reports no differences for an empty record list" do
    rendered = lines(Render.core_diff(%{"generation" => "gen-1", "backend_diff" => []}))

    assert "no differences" in rendered
  end
end
