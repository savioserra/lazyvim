defmodule Workstation.CLI.TUI.ShellHomeFrameTest do
  @moduledoc """
  Home responsiveness as pure frames: the shell's own `view/1` rendered
  at pinned sizes with fully loaded fixture wires — no runtime, no async
  (the same pure-test split pure_drill_test.exs uses for the browser).

  Stage B contract:

    * widths >= 110 columns own the full 2x2 mosaic plus the full-width
      capabilities band;
    * below 110 columns the five dashboard boxes stack vertically in the
      brief priority (engine > journal > domains > plan/diff), each box
      full width, on bounded-fill tracks that keep the boxes' minimum
      heights and shrink them proportionally when the body runs short;
    * no border row ever breaks at any size: every top/bottom border
      closes its far corner, and `Shell.Box` border islands elide
      (ellipsis-trimmed, then dropped, right-to-left) before a corner
      yields.
  """

  use ExUnit.Case, async: true

  alias TermUI.Frame
  alias TermUI.Style
  alias Workstation.CLI.Capabilities
  alias Workstation.CLI.TUI.Shell
  alias Workstation.CLI.TUI.Shell.Box
  alias Workstation.CLI.TUI.Shell.CapabilitiesBrowser
  alias Workstation.CLI.TUI.Theme

  @mosaic_width 110

  describe "home mosaic (width >= #{@mosaic_width})" do
    test "175x83: engine/journal and plan/diff quadrant rows plus the full-width band" do
      frame = home_frame(175, 83)
      assert_closed_borders(frame)

      assert [engine_row, plan_row, caps_row] = box_top_rows(frame)

      # Quadrant pair one on a single border row: engine left, journal right.
      assert Frame.row_text(frame, engine_row) =~ "╭─┐1 engine"
      assert right_half(frame, engine_row) =~ "┐ journal ┌"

      # Quadrant pair two: plan left (with its would-change badge), diff right.
      assert Frame.row_text(frame, plan_row) =~ "╭─┐4 plan"
      assert right_half(frame, plan_row) =~ "┐5 diff ┌"

      # The capabilities band spans the whole frame: corners on the edges.
      caps_text = Frame.row_text(frame, caps_row)
      assert caps_text =~ "╭─┐2 capabilities"
      assert String.starts_with?(caps_text, "╭")
      assert String.ends_with?(String.trim_trailing(caps_text), "╮")
    end

    test "#{@mosaic_width} columns is still the mosaic (the inclusive boundary)" do
      frame = home_frame(@mosaic_width, 40)
      assert_closed_borders(frame)

      assert [engine_row, plan_row, _caps_row] = box_top_rows(frame)
      assert Frame.row_text(frame, engine_row) =~ "╭─┐1 engine"
      assert right_half(frame, engine_row) =~ "┐ journal ┌"
      assert Frame.row_text(frame, plan_row) =~ "╭─┐4 plan"
      assert right_half(frame, plan_row) =~ "┐5 diff ┌"
    end

    test "the update hint rides the capabilities band when the band has room" do
      for {width, height} <- [{175, 83}, {@mosaic_width, 40}] do
        frame = home_frame(width, height, update_hint: %{"local" => "v1", "remote" => "v2"})
        assert_closed_borders(frame)
        assert full_text(frame) =~ "↑ update available (v1 → v2) — [u] update"
      end
    end

    test "a stacked home keeps advertising the update through the buttonbar" do
      frame = home_frame(80, 24, update_hint: %{"local" => "v1", "remote" => "v2"})
      assert_closed_borders(frame)
      assert full_text(frame) =~ "┘u update└"
    end
  end

  describe "home vertical stack (width < #{@mosaic_width})" do
    test "80x24: five full-width boxes in priority order, borders closed" do
      frame = home_frame(80, 24)
      assert_closed_borders(frame)

      rows = box_top_rows(frame)
      titles = Enum.map(rows, &box_title(frame, &1))

      # Brief priority: engine > journal > domains > plan/diff.
      assert titles == [
               "1 engine",
               "journal",
               "2 capabilities",
               "4 plan",
               "5 diff"
             ]

      # Every stacked box owns the full width: its border opens on the
      # first and closes on the last column.
      Enum.each(rows, fn row ->
        text = Frame.row_text(frame, row)
        assert String.starts_with?(text, "╭")
        assert String.ends_with?(String.trim_trailing(text), "╮")
      end)
    end

    test "one column below the boundary falls back to the stack" do
      narrow = home_frame(@mosaic_width - 1, 24)

      assert [engine_row, journal_row | _rest] = box_top_rows(narrow)
      # Stacked boxes title on separate rows (no side-by-side halves).
      refute Frame.row_text(narrow, engine_row) =~ "journal"
      assert box_title(narrow, journal_row) == "journal"
    end
  end

  describe "border island elision (Shell.Box)" do
    test "a too-long title truncates with an ellipsis, corners stay closed" do
      frame = Box.frame([], {24, 3}, title: "a very long box title indeed")

      assert_closed_borders(frame)
      top = Frame.row_text(frame, 1)

      assert top =~ "┐a very long box ti…┌"
      refute String.contains?(top, "indeed")
    end

    test "right islands yield right-to-left before the title" do
      style = Style.new()

      frame =
        Box.frame([], {30, 3},
          title: "engine",
          right: [[{"● reachable", style}], [{"gen 2/7", style}]]
        )

      assert_closed_borders(frame)
      top = Frame.row_text(frame, 1)

      # The title survives intact; the rightmost badge island drops whole.
      assert top =~ "┐engine┌"
      assert top =~ "┐● reachable┌"
      refute String.contains?(top, "gen 2/7")
    end

    test "buttonbars drop the counter, then trailing buttons; corners stay closed" do
      style = Style.new()

      frame =
        Box.frame([], {20, 3},
          buttons: [
            [{"a", style}, {" apply", style}],
            [{"u", style}, {" update", style}],
            [{"r", style}, {" refresh", style}]
          ],
          counter: "1/41"
        )

      assert_closed_borders(frame)
      bottom = Frame.row_text(frame, 3)

      # Leftmost action keys survive; the rightmost affordances elide.
      assert bottom =~ "┘a apply└"
      refute String.contains?(bottom, "refresh")
      refute String.contains?(bottom, "1/41")
    end

    test "degenerate widths keep plain closed corners" do
      style = Style.new()

      for width <- [2, 3, 4, 6, 12] do
        frame =
          Box.frame([], {width, 3},
            title: "engine",
            right: [{"123456", style}],
            buttons: [[{"a", style}, {" apply", style}]],
            counter: "1/41"
          )

        assert_closed_borders(frame)
      end
    end
  end

  ## helpers

  # Every border a box draws closes its far corner, and no row paints
  # beyond the frame width (Frame pads rows to exactly `width`).
  defp assert_closed_borders(frame) do
    for row <- 1..frame.height do
      text = Frame.row_text(frame, row)
      assert String.length(text) == frame.width

      if String.contains?(text, "╭"), do: assert(text =~ "╮")
      if String.contains?(text, "╰"), do: assert(text =~ "╯")
    end
  end

  # Rows carrying a box's top border (a rounded corner opening).
  defp box_top_rows(frame) do
    1..frame.height
    |> Enum.filter(&(Frame.row_text(frame, &1) =~ "╭"))
    |> then(fn rows ->
      assert rows != [], "expected boxed panes, found none"
      rows
    end)
  end

  # The title island text of a box's top border row (between ┐ and ┌).
  defp box_title(frame, row) do
    text = Frame.row_text(frame, row)
    [_, title] = Regex.run(~r/┐\s*([^┌]*?)\s*┌/, text)
    title
  end

  defp right_half(frame, row) do
    frame
    |> Frame.row_text(row)
    |> String.slice(div(frame.width, 2), frame.width)
  end

  ## fixtures: a fully loaded shell state, rendered directly

  defp home_frame(width, height, opts \\ []) do
    state = %Shell{
      destination: "/tmp/workstation-home-frame-test-home",
      theme: Theme.base_colors(:dark),
      tab: :home,
      last_data_tab: :home,
      cache: %{status: {:ok, status_wire()}, plan: {:ok, plan_wire()}, diff: {:ok, diff_wire()}},
      caps: caps_browser(),
      caps_env: caps_envelope(),
      text_views: %{},
      op: nil,
      load: fn _wire -> {:ok, %{}} end,
      executor: fn _plan -> :ok end,
      update_executor: fn _flow -> :ok end,
      check: fn -> {:ok, %{"status" => "up_to_date"}} end,
      update_hint: Keyword.get(opts, :update_hint),
      toast_ms: 60_000,
      now: ~U[2026-02-13T12:00:00Z],
      dimensions: {width, height}
    }

    Shell.view(state)
  end

  defp full_text(frame) do
    Enum.map_join(1..frame.height, "\\n", &Frame.row_text(frame, &1))
  end

  defp caps_browser, do: CapabilitiesBrowser.init(caps_envelope())

  defp caps_envelope, do: Capabilities.group(%{"status" => status_wire(), "plan" => plan_wire()})

  defp status_wire do
    %{
      "destination" => "/tmp/workstation-home-frame-test-home",
      "platform" => "linux-test",
      "engine" => %{"name" => "workstation", "version" => "9.9.9-frame", "mode" => "frame"},
      "taxonomy" => %{
        "nvim" => "foundation/editor",
        "helix" => "foundation/editor",
        "tmux" => "foundation/terminal"
      },
      "packages" => [
        %{"id" => "nvim", "name" => "nvim", "targets" => [".config/nvim"]},
        %{"id" => "helix", "name" => "helix", "targets" => [".config/helix"]},
        %{"id" => "tmux", "name" => "tmux", "targets" => [".config/tmux"]}
      ],
      "graph_order" => ["tmux", "helix", "nvim"],
      "journal" => %{"generation" => 2, "revision" => 7, "applied_at" => "2026-02-13T10:00:00Z"}
    }
  end

  defp plan_wire do
    %{
      "generation" => "gen-3",
      "plan" => %{
        "entries" => [
          %{
            "source_name" => "dot_config/nvim/init.lua",
            "target" => ".config/nvim/init.lua",
            "attribution" => ["nvim"]
          },
          %{
            "source_name" => "dot_config/helix/config.toml",
            "target" => ".config/helix/config.toml",
            "attribution" => ["helix"]
          },
          %{
            "source_name" => "dot_config/tmux/tmux.conf",
            "target" => ".config/tmux/tmux.conf",
            "attribution" => ["tmux"]
          }
        ],
        "removals" => []
      },
      "patches" => []
    }
  end

  defp diff_wire do
    %{
      "destination" => "/tmp/workstation-home-frame-test-home",
      "backend_diff" => [
        %{"kind" => "write", "target" => ".config/nvim/init.lua", "source" => "nvim/init.lua"}
      ]
    }
  end
end
