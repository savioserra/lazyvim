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

  # async: false — the width sweep pins every scheduler for ~a minute
  # (4 parallel render legs); as a sync module it runs exclusively, so
  # timing-sensitive runtime suites never fight it for cores.
  use ExUnit.Case, async: false

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

  describe "box side borders (Shell.Box)" do
    test "body rows carry both side borders on the corner columns at every width" do
      # Regression pin: content rows once rendered one column short — the
      # right border rode `width - 1` (and the left border was missing
      # entirely), so body rows disagreed with their own border rows.
      for width <- [2, 3, 7, 12, 80, 101, 102, 103, 175, 204, 241] do
        frame = Box.frame([[{"hello", Style.new()}]], {width, 4}, [])
        assert_closed_borders(frame)

        for row <- 2..3 do
          assert Frame.cell(frame, row, 1).char == "│",
                 "width #{width} row #{row}: missing left border"

          assert Frame.cell(frame, row, width).char == "│",
                 "width #{width} row #{row}: right border not on column #{width}"
        end
      end
    end
  end

  ## geometry: a width sweep pinning the cell-level frame contract at
  ## EVERY width class — the pinned 3-size matrix (80/110/175) missed
  ## whole width classes (a 204-column terminal rendered every content
  ## row one column short of its border rows)

  @sweep_heights [24, 40, 55, 83]
  # Chrome glyphs allowed on a box's side-border columns across body rows
  # (the right border swaps to scrollbar glyphs while content overflows).
  @side_glyphs ["│", "╥", "║", "╙", "╟", "╢"]
  @border_glyphs ["│", "─", "╭", "╮", "╰", "╯", "┬", "┴", "├", "┤", "┘", "└", "═"]

  describe "width sweep 80..240 (corner parity + column consistency)" do
    @tag timeout: 300_000
    test "border rows and content rows share identical columns at every width" do
      # One leg per height class, run concurrently inside the test: a
      # 644-frame render sweep is minutes of pure function calls, and
      # ExUnit only parallelizes across modules.
      legs =
        @sweep_heights
        |> Task.async_stream(
          fn height ->
            Enum.each(80..240, fn width ->
              frame = home_frame(width, height)
              assert frame.width == width
              assert frame.height == height

              census = border_census(frame)
              assert_corner_parity(census, width, height)
              assert_box_columns(frame, census, width, height)
              assert_full_width_bars(frame)
            end)
          end,
          timeout: :infinity
        )
        |> Enum.to_list()

      assert length(legs) == length(@sweep_heights)
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

  # Cell-level chrome census: %{row => %{col => glyph}}, built by walking
  # `frame.cells` directly — Frame.row_text/2 regex-sanitizes per cell and
  # is far too slow inside a 644-frame sweep.
  defp border_census(frame) do
    glyphs = MapSet.new(@border_glyphs)

    Enum.reduce(frame.cells, %{}, fn {{row, col}, cell}, acc ->
      if MapSet.member?(glyphs, cell.char) do
        Map.update(acc, row, %{col => cell.char}, &Map.put(&1, col, cell.char))
      else
        acc
      end
    end)
  end

  defp census_glyph(census, row, col), do: Map.get(census[row] || %{}, col)

  # Corner parity: on every row the ╭ columns pair in order with the ╮
  # columns to their right (a corner never opens without closing).
  defp assert_corner_parity(census, width, height) do
    Enum.each(census, fn {row, cols} ->
      tops = Enum.sort(for {col, "╭"} <- cols, do: col)
      caps = Enum.sort(for {col, "╮"} <- cols, do: col)

      assert length(tops) == length(caps),
             "#{width}x#{height} row #{row}: #{length(tops)} ╭ vs #{length(caps)} ╮"

      tops
      |> Enum.zip(caps)
      |> Enum.each(fn {open, close} ->
        assert open < close,
               "#{width}x#{height} row #{row}: ╮ at #{close} does not close ╭ at #{open}"
      end)
    end)
  end

  # Column consistency: every box (a ╭ at row/col c1 paired with a ╮ at
  # c2 on the same row) closes with ╰/╯ on the SAME columns, and every
  # body row between rides a side-border glyph on exactly those columns —
  # content rows may never drop or shift a border column.
  defp assert_box_columns(frame, census, width, height) do
    Enum.each(census, fn {row, cols} ->
      tops = Enum.sort(for {col, "╭"} <- cols, do: col)
      caps = Enum.sort(for {col, "╮"} <- cols, do: col)

      tops
      |> Enum.zip(caps)
      |> Enum.each(fn {c1, c2} ->
        bottom = Enum.find((row + 1)..frame.height, &(census_glyph(census, &1, c1) == "╰"))

        assert bottom,
               "#{width}x#{height}: box opened at row #{row} cols #{c1}-#{c2} never closes"

        assert census_glyph(census, bottom, c2) == "╯",
               "#{width}x#{height} row #{bottom}: ╯ not on column #{c2}"

        for r <- (row + 1)..(bottom - 1) do
          assert census_glyph(census, r, c1) in @side_glyphs,
                 "#{width}x#{height} row #{r}: column #{c1} lost the box side border"

          assert census_glyph(census, r, c2) in @side_glyphs,
                 "#{width}x#{height} row #{r}: column #{c2} lost the box side border"
        end
      end)
    end)
  end

  # The chrome bars span the terminal: the header's double rule covers
  # every column; the tab strip (the row below the rule) and the footer
  # (the last row) open with a keycap island on column 1 and their chrome
  # `─` filler carries the bar to the right edge — the run from the last
  # island to the edge is pure filler (a bar that stops early leaves
  # background blanks and fails the tail check).
  defp assert_full_width_bars(frame) do
    rule_row = Enum.find(1..frame.height, &(Frame.cell(frame, &1, 1).char == "═"))
    assert rule_row, "header double rule not found"

    for c <- 1..frame.width do
      assert Frame.cell(frame, rule_row, c).char == "═",
             "header rule hole at column #{c}"
    end

    strip_row = rule_row + 1

    assert Frame.cell(frame, strip_row, 1).char == "┘",
           "strip does not open on column 1"

    for c <- 1..frame.width do
      assert Frame.cell(frame, strip_row, c).char != " ",
             "strip hole at column #{c}"
    end

    footer_row = frame.height

    assert Frame.cell(frame, footer_row, 1).char == "┘",
           "footer does not open on column 1"

    assert_chrome_filler_to_edge(frame, strip_row, "strip")
    assert_chrome_filler_to_edge(frame, footer_row, "footer")
  end

  # Scanning right to left from the terminal edge, the bar must ride the
  # chrome filler (`─`) without a single blank until the last island's
  # closing connector.
  defp assert_chrome_filler_to_edge(frame, row, what) do
    tail =
      frame.width
      |> Stream.iterate(&(&1 - 1))
      |> Stream.take_while(fn c -> c >= 1 and Frame.cell(frame, row, c).char == "─" end)
      |> Enum.to_list()

    assert tail != [], "#{what} does not ride the chrome filler to column #{frame.width}"
    assert length(tail) < frame.width, "#{what} has no keycap islands"

    last_island_col = frame.width - length(tail)

    assert Frame.cell(frame, row, last_island_col).char == "└",
           "#{what} filler does not meet the last island at column #{last_island_col}"
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
