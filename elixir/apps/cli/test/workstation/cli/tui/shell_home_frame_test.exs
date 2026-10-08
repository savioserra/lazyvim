defmodule Workstation.CLI.TUI.ShellHomeFrameTest do
  @moduledoc """
  Dashboard responsiveness as pure frames: the shell's own `view/1`
  rendered at pinned sizes with fully loaded fixture wires — no runtime,
  no async (the same pure-test split pure_drill_test.exs uses for the
  browser).

  The dashboard IS the app — one six-box surface:

    * preset 0 (full) at widths >= 110 columns owns the slot mosaic:
      engine/journal and plan/diff quadrant rows, the full-width
      capabilities band, the full-width status band;
    * below 110 columns (and whenever preset tracking is dissolved) the
      visible boxes stack vertically in fixed priority (engine, journal,
      capabilities, plan, diff, status), each full width on bounded-fill
      tracks that keep the boxes' minimum heights and shrink them
      proportionally when the body runs short;
    * presets 1 (audit) and 2 (minimal) re-tile their own membership —
      audit: plan|diff on top, engine|journal as a bottom band at any
      width; minimal: engine|journal filling the body;
    * no border row ever breaks at any size: every top/bottom border
      closes its far corner, and `Shell.Box` border islands elide
      (ellipsis-trimmed, then dropped, right-to-left) before a corner
      yields.
  """

  # async: false — the width sweep pins every scheduler for ~a minute
  # (parallel render legs); as a sync module it runs exclusively, so
  # timing-sensitive runtime suites never fight it for cores.
  use ExUnit.Case, async: false

  alias TermUI.Frame
  alias TermUI.Style
  alias Workstation.CLI.Capabilities
  alias Workstation.CLI.TUI.Shell
  alias Workstation.CLI.TUI.Shell.Box
  alias Workstation.CLI.TUI.Shell.CapabilitiesBrowser
  alias Workstation.CLI.TUI.Shell.Dashboard
  alias Workstation.CLI.TUI.Theme

  @mosaic_width 110

  describe "home mosaic (width >= #{@mosaic_width})" do
    test "175x83: engine/journal and plan/diff quadrant rows plus the two full-width bands" do
      frame = home_frame(175, 83)
      assert_closed_borders(frame)

      assert [engine_row, plan_row, caps_row, status_row] = box_top_rows(frame)

      # Quadrant pair one on a single border row: engine left, journal right.
      assert Frame.row_text(frame, engine_row) =~ "╭─┐¹engine"
      assert right_half(frame, engine_row) =~ "┐³journal┌"

      # Quadrant pair two: plan left (with its would-change badge), diff right.
      assert Frame.row_text(frame, plan_row) =~ "╭─┐⁴plan"
      assert right_half(frame, plan_row) =~ "┐⁵diff┌"

      # The capabilities band spans the whole frame: corners on the edges.
      caps_text = Frame.row_text(frame, caps_row)
      assert caps_text =~ "╭─┐²capabilities"
      assert String.starts_with?(caps_text, "╭")
      assert String.ends_with?(String.trim_trailing(caps_text), "╮")

      # The status band too — the deep-rows box that absorbed the old
      # daemon tab (destination, platform, graph order, generation,
      # revision).
      status_text = Frame.row_text(frame, status_row)
      assert status_text =~ "╭─┐⁶status"
      assert String.starts_with?(status_text, "╭")
      assert String.ends_with?(String.trim_trailing(status_text), "╮")

      body = full_text(frame)
      assert body =~ "destination:"
      assert body =~ "graph order:"
      assert body =~ "generation:  2"
      # The status band is a fixed 5 rows, so its tail rows (generation,
      # revision) elide at this height — the deep rows are pinned by the
      # runtime suite's status-box tests instead.
    end

    test "#{@mosaic_width} columns is still the mosaic (the inclusive boundary)" do
      frame = home_frame(@mosaic_width, 40)
      assert_closed_borders(frame)

      assert [engine_row, plan_row, _caps_row, _status_row] = box_top_rows(frame)
      assert Frame.row_text(frame, engine_row) =~ "╭─┐¹engine"
      assert right_half(frame, engine_row) =~ "┐³journal┌"
      assert Frame.row_text(frame, plan_row) =~ "╭─┐⁴plan"
      assert right_half(frame, plan_row) =~ "┐⁵diff┌"
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

  describe "presets" do
    test "audit (preset 1): plan/diff on top, engine/journal band, at any width" do
      for {width, height} <- [{175, 83}, {@mosaic_width, 40}, {80, 24}] do
        frame = home_frame(width, height, dashboard: preset(1))
        assert_closed_borders(frame)

        rows = box_top_rows(frame)
        titles = Enum.map(rows, &box_title(frame, &1))

        # Two quadrant rows: plan|diff fill the top, engine|journal ride
        # the fixed bottom band (each pair's right half named in its row).
        assert titles == ["⁴plan", "¹engine"]
        assert right_half(frame, hd(rows)) =~ "┐⁵diff┌"
        assert right_half(frame, List.last(rows)) =~ "┐³journal┌"
        refute full_text(frame) =~ "²capabilities"
        refute full_text(frame) =~ "⁶status"

        # Hidden boxes render NOWHERE — there is no dimmed strip island
        # anymore; the boxes' superscript titles are the only toggle
        # advertising.
        refute Frame.row_text(frame, 1) =~ "[2] capabilities"
      end
    end

    test "minimal (preset 2): only engine and journal, filling the body" do
      for {width, height} <- [{175, 83}, {80, 24}] do
        frame = home_frame(width, height, dashboard: preset(2))
        assert_closed_borders(frame)

        rows = box_top_rows(frame)
        assert Enum.map(rows, &box_title(frame, &1)) == ["¹engine"]

        # One quadrant row: engine left, journal right, both filling.
        [only_r] = rows
        assert String.starts_with?(Frame.row_text(frame, only_r), "╭")
        assert String.ends_with?(String.trim_trailing(Frame.row_text(frame, only_r)), "╮")
        assert right_half(frame, only_r) =~ "┐³journal┌"
      end
    end

    test "dissolved tracking tiles generic slots with the remaining membership" do
      # Toggle two boxes off preset 0: the tracking dissolves and the
      # generic tiler re-flows the survivors — no preset rows anymore.
      dash =
        Dashboard.new()
        |> Dashboard.toggle_box(:plan, 175)
        |> then(fn {:ok, d} -> d end)
        |> Dashboard.toggle_box(:status, 175)
        |> then(fn {:ok, d} -> d end)

      frame = home_frame(175, 83, dashboard: dash)
      assert_closed_borders(frame)

      rows = box_top_rows(frame)
      titles = Enum.map(rows, &box_title(frame, &1))

      # Slot priority with plan and status gone: engine|journal, then the
      # lone diff box full width, then the capabilities band.
      assert titles == ["¹engine", "⁵diff", "²capabilities"]

      # Hidden boxes render nowhere (no dimmed strip islands — the
      # superscript titles are the only toggle advertising).
      refute full_text(frame) =~ "⁴plan"
      refute full_text(frame) =~ "⁶status"
    end
  end

  describe "home vertical stack (width < #{@mosaic_width})" do
    test "80x24: six full-width boxes in priority order, borders closed" do
      frame = home_frame(80, 24)
      assert_closed_borders(frame)

      rows = box_top_rows(frame)
      titles = Enum.map(rows, &box_title(frame, &1))

      # Fixed stack priority: engine > journal > capabilities > plan >
      # diff > status — every box glowing its keycap.
      assert titles == [
               "¹engine",
               "³journal",
               "²capabilities",
               "⁴plan",
               "⁵diff",
               "⁶status"
             ]

      # Every stacked box owns the full width: its border opens on the
      # first and closes on the last column.
      Enum.each(rows, fn row ->
        text = Frame.row_text(frame, row)
        assert String.starts_with?(text, "╭")
        assert String.ends_with?(String.trim_trailing(text), "╮")
      end)
    end

    test "stacked boxes carry their per-domain border role (F1-full)" do
      frame = home_frame(80, 24)
      [engine_r, journal_r, caps_r, plan_r, diff_r, status_r] = box_top_rows(frame)

      # Dark-base token hues from the docs/theme.md border role table:
      # engine/plan blue, journal/status green, capabilities yellow,
      # diff red — all resolved through the theme, never hardcoded in
      # the box painter. Starlight brand values (v4).
      assert Frame.cell(frame, engine_r, 1).fg == {91, 173, 255}
      assert Frame.cell(frame, journal_r, 1).fg == {127, 207, 120}
      assert Frame.cell(frame, caps_r, 1).fg == {240, 230, 140}
      assert Frame.cell(frame, plan_r, 1).fg == {91, 173, 255}
      assert Frame.cell(frame, diff_r, 1).fg == {255, 121, 121}
      assert Frame.cell(frame, status_r, 1).fg == {127, 207, 120}

      # Enabled buttonbar labels read text (dark base #f5f5dc); the
      # keycap stays shortcut. Find the caps band's buttonbar row — the
      # box body may spend any number of rows above it.
      buttonbar_row =
        Enum.find(caps_r..frame.height, fn row ->
          Frame.row_text(frame, row) =~ "a apply"
        end)

      assert buttonbar_row != nil
      caps_bottom = Frame.row_text(frame, buttonbar_row)

      # Column of the label's first glyph (codepoint count of the prefix).
      label_col =
        caps_bottom
        |> String.split("apply", parts: 2)
        |> List.first()
        |> String.length()
        |> Kernel.+(1)

      assert Frame.cell(frame, buttonbar_row, label_col).fg == {245, 245, 220}
    end

    test "one column below the boundary falls back to the stack" do
      narrow = home_frame(@mosaic_width - 1, 24)

      assert [engine_row, journal_row | _rest] = box_top_rows(narrow)
      # Stacked boxes title on separate rows (no side-by-side halves).
      refute Frame.row_text(narrow, engine_row) =~ "journal"
      assert box_title(narrow, journal_row) == "³journal"
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
  @preset_sweep_heights [24, 55]
  # Chrome glyphs allowed on a box's side-border columns across body rows
  # (the right border swaps to scrollbar glyphs while content overflows).
  @side_glyphs ["│", "╥", "║", "╙", "╟", "╢"]
  @border_glyphs ["│", "─", "╭", "╮", "╰", "╯", "┬", "┴", "├", "┤", "┘", "└"]

  describe "width sweep 80..240 (corner parity + column consistency)" do
    @tag timeout: 300_000
    test "preset 0 keeps closed borders at every width" do
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

    @tag timeout: 300_000
    test "presets 1, 2 and dissolved tracking keep closed borders at every width" do
      legs =
        @preset_sweep_heights
        |> Task.async_stream(
          fn height ->
            Enum.each(80..240, fn width ->
              dashboards = [
                {"preset 1", preset(1)},
                {"preset 2", preset(2)},
                {"dissolved", dissolved(width)}
              ]

              Enum.each(dashboards, fn {what, dash} ->
                frame = home_frame(width, height, dashboard: dash)
                assert frame.width == width, "#{what} #{width}x#{height}"
                assert frame.height == height, "#{what} #{width}x#{height}"

                census = border_census(frame)
                assert_corner_parity(census, width, height)
                assert_box_columns(frame, census, width, height)
                assert_full_width_bars(frame)
              end)
            end)
          end,
          timeout: :infinity
        )
        |> Enum.to_list()

      assert length(legs) == length(@preset_sweep_heights)
    end
  end

  ## helpers

  # preset(1)/(2) via the real cycle path — the same membership the key
  # presses produce.
  defp preset(1), do: Dashboard.new() |> Dashboard.cycle(:next)
  defp preset(2), do: Dashboard.new() |> Dashboard.cycle(:next) |> Dashboard.cycle(:next)

  # A dissolved tracker with the status box toggled off (any width: the
  # min-size gate only blocks turning a box ON).
  defp dissolved(width) do
    {:ok, dash} = Dashboard.toggle_box(Dashboard.new(), :status, width)
    dash
  end

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

    # /u: the keycap superscripts (U+2070-2079 share their leading byte
    # with the island glyphs) must read as single codepoints, not bytes —
    # byte-wise, [^┌] rejects the keycap and the match skips islands.
    [_, title] = Regex.run(~r/┐\s*([^┌]*?)\s*┌/u, text)
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
      dashboard: Keyword.get(opts, :dashboard, Dashboard.new()),
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
    Enum.map_join(1..frame.height, "\n", &Frame.row_text(frame, &1))
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

  # The chrome bars span the terminal: the footer (the last row) opens
  # with a keycap island on column 1 and its chrome `─` filler carries
  # the bar to the right edge — the run from the last island to the edge
  # is pure filler (a bar that stops early leaves background blanks and
  # fails the tail check). There is no top strip anymore: the FIRST row
  # is the dashboard's first box row — its border opens on column 1.
  defp assert_full_width_bars(frame) do
    assert Frame.cell(frame, 1, 1).char == "╭",
           "the dashboard's first box row does not own the top terminal row"

    footer_row = frame.height

    assert Frame.cell(frame, footer_row, 1).char == "┘",
           "footer does not open on column 1"

    assert_island_discipline(frame, footer_row, "footer")
    assert_chrome_filler_to_edge(frame, footer_row, "footer")
  end

  # Islands may carry interior spaces (`p next`, `[4] plan` — the btop
  # island grammar); what may never happen is a space hugging a
  # connector glyph — that would mean a gap between islands or a
  # half-drawn one.
  defp assert_island_discipline(frame, row, what) do
    for c <- 1..frame.width do
      if Frame.cell(frame, row, c).char == " " do
        left = if c > 1, do: Frame.cell(frame, row, c - 1).char, else: "─"
        right = if c < frame.width, do: Frame.cell(frame, row, c + 1).char, else: "─"

        refute left in ["┘", "└"], "#{what}: island gap before column #{c}"
        refute right in ["┘", "└"], "#{what}: island gap after column #{c}"
      end
    end
  end

  # Scanning right to left from the terminal edge, the bar must either
  # close flush with an island's connector (an exact fit — the islands
  # span the full width) or ride the chrome filler (`─`) without a
  # single blank until the last island's closing connector.
  defp assert_chrome_filler_to_edge(frame, row, what) do
    last = Frame.cell(frame, row, frame.width).char

    if last == "└" do
      :ok
    else
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
