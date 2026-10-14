defmodule Workstation.CLI.TUI.Shell.Box do
  @moduledoc """
  btop box anatomy — the one builder every boxed pane goes through.

  The screen body is a mosaic of adjacent rounded boxes on the terminal
  background (no filled panels). Each box owns its border chrome:

    * the title is an ISLAND inside the top border run, opened by `┐` and
      closed by `┌`: `╭─┐3 status┌──────────`; the keycap digit rides the
      shortcut slot inside the island (the caller styles the spans);
    * an optional right island on the top border carries counters/badges:
      `──────┐2/41┌─╮` — position counters live HERE (title-side), never
      welded into a mid-border run;
    * the bottom border doubles as the box's buttonbar — buttons are
      `┘label└` islands: `╰┘↑↓ scroll└┘r refresh└─────╯`;
    * on overflow the right border becomes a block scrollbar
      (`▲` above, `█` thumb, `▏` track, `▼` below) hugging the border.

  Boxes are pure Frame builders over span rows, so deterministic frame
  tests (pinned wires, no daemon) assert the anatomy cell-by-cell. All
  colors arrive as theme-role styles from the caller — this module never
  hardcodes one.
  """

  alias TermUI.Cell
  alias TermUI.Frame
  alias TermUI.Style
  alias TermUI.Widget.Helpers

  @type row :: Frame.row()
  @type spans :: [String.t() | {String.t(), Style.t()}]
  @type scrollbar :: {offset :: non_neg_integer(), visible :: pos_integer(), total :: pos_integer()}

  @doc """
  One rounded box. Options:

    * `:border_style` — the chrome style for every border run (default: plain)
    * `:title` — island content on the top border, spans or plain binary
    * `:right` — right island content on the top border (counters/badges):
      one island (spans/binary) or a list of islands, rendered left to
      right as `┐…┌┐…┌` before the corner
    * `:buttons` — list of buttonbar button contents (spans or binary),
      rendered as `┘…└` islands on the bottom border left-to-right
    * `:scrollbar` — `{offset, visible, total}`; swaps the right border to
      the block scrollbar while the content overflows
    * `:thumb_style` — scrollbar thumb style (default: the border style)

  Border islands elide gracefully on narrow boxes: right islands yield
  right-to-left (trimmed with an ellipsis while any cell survives, then
  dropped), the title truncates before its island connectors are
  surrendered, and the closing corners always land inside the box width —
  a border row is never left without its far corner at any size.
  """
  @spec frame([row()], TermUI.Widget.dimensions(), keyword()) :: Frame.t()
  def frame(rows, {width, height}, opts) do
    border = Keyword.get(opts, :border_style, Style.new())
    inner_w = max(width - 2, 0)
    inner_h = max(height - 2, 0)

    top = top_row(width, Keyword.get(opts, :title), Keyword.get(opts, :right), border)
    bottom = bottom_row(width, Keyword.get(opts, :buttons, []), border)
    body = body_rows(rows, inner_w, inner_h, border, opts)

    Frame.from_rows([top] ++ body ++ [bottom], width, height)
  end

  @doc "Width of one island/button content (island connectors excluded)."
  @spec content_width(spans() | String.t()) :: non_neg_integer()
  def content_width(spans) when is_binary(spans), do: Helpers.text_width(spans)

  def content_width(spans) when is_list(spans) do
    Enum.reduce(spans, 0, fn
      {text, _style}, acc -> acc + Helpers.text_width(text)
      text, acc when is_binary(text) -> acc + Helpers.text_width(text)
    end)
  end

  @doc """
  Normalizes island/button content to styled spans: a bare binary becomes
  `{text, style}`; span lists pass through.
  """
  @spec spans(spans() | String.t(), Style.t()) :: spans()
  def spans(text, style) when is_binary(text), do: [{text, style}]
  def spans(spans, _style) when is_list(spans), do: spans

  ## border runs

  # `╭─┐TITLE┌──────┐RIGHT┌┐RIGHT┌─╮` — islands break the dash run; with
  # neither island the top border is a plain rounded run. Right content
  # is one island or a list of islands (span-list elements), so counters
  # can ride the border as separate islands. Everything between the
  # corners elides to the corner budget (width - 2) so the row always
  # closes.
  defp top_row(width, title, right, border) do
    budget = width - 2
    left = title_island(as_spans(title), border, budget)
    {left, islands} = fit_border(left, right_islands(right), budget)

    middle = String.duplicate("─", max(budget - content_width(left) - islands_width(islands), 0))

    [{"╭", border}] ++
      left ++ [{middle, border}] ++ render_right_islands(islands, border) ++ [{"╮", border}]
  end

  # The title island keeps its `─┐` / `┌` connectors at any width: the
  # island TEXT truncates first, and only a box narrower than the bare
  # connectors gives the island up entirely.
  defp title_island(nil, _border, _budget), do: []

  defp title_island(spans, border, budget) do
    left = [{"─┐", border}] ++ spans ++ [{"┌", border}]

    if content_width(left) <= budget do
      left
    else
      if budget >= 4 do
        [{"─┐", border}] ++ truncate_spans(spans, budget - 3) ++ [{"┌", border}]
      else
        []
      end
    end
  end

  defp render_right_islands([], _border), do: []

  defp render_right_islands(islands, border) do
    islands
    |> Enum.flat_map(fn spans -> [{"┐", border}] ++ spans ++ [{"┌", border}] end)
    |> Kernel.++([{"─", border}])
  end

  # Width a non-empty island list occupies between the corners, including
  # the separator dash rendered after the last island.
  defp islands_width([]), do: 0

  defp islands_width(islands),
    do: Enum.reduce(islands, 1, &(2 + content_width(&1) + &2))

  # Elides the right islands into the corner budget: the rightmost island
  # trims against the leftover room (an ellipsis closes a cut run), a
  # whole island drops once nothing survives, and the pre-sized title on
  # the left never needs to yield.
  defp fit_border(left, islands, budget) do
    cond do
      content_width(left) + islands_width(islands) <= budget ->
        {left, islands}

      islands == [] ->
        {left, []}

      true ->
        init = Enum.drop(islands, -1)
        # The closing dash (`islands_width/1` base 1) rides in the room
        # too: without reserving it, an ellipsis-trimmed island lands at
        # exactly room - 2 wide and the row still overruns by one cell,
        # so the trim recursion spins on an unchanged island forever (the
        # portrait / short-screen render stall).
        room = budget - content_width(left) - islands_width(init) - 1
        trimmed = trim_island(List.last(islands), room)

        if content_width(trimmed) > 0 do
          fit_border(left, init ++ [trimmed], budget)
        else
          fit_border(left, init, budget)
        end
    end
  end

  # Island connective tissue costs 2 cells; the text gets what remains.
  # Below 6 cells of room a trimmed island would render as a lone glyph
  # (no space for a closing ellipsis) — drop it instead.
  defp trim_island(spans, room) when room >= 6, do: truncate_spans(spans, room - 2)
  defp trim_island(_spans, _room), do: []

  # Display-width-aware span truncation; a cut run closes with an
  # ellipsis when one still fits.
  defp truncate_spans(spans, budget) do
    {kept, _used} =
      Enum.reduce(spans, {[], 0}, fn span, {acc, used} ->
        if used >= budget do
          {acc, used}
        else
          {text, style} = split_span(span)
          {visible, visible_width} = Cell.truncate(text, budget - used)

          # A cut run reserves its last cell for the closing ellipsis —
          # elision is always advertised as elision.
          visible =
            if visible_width < Cell.text_width(text) and budget - used >= 1 do
              {shorter, _shorter_width} = Cell.truncate(text, budget - used - 1)
              shorter <> "…"
            else
              visible
            end

          rendered = if style, do: {visible, style}, else: visible
          {[rendered | acc], used + Cell.text_width(visible)}
        end
      end)

    Enum.reverse(kept)
  end

  defp split_span({text, style}) when is_binary(text), do: {text, style}
  defp split_span(text) when is_binary(text), do: {text, nil}

  # One island (spans: elements are binaries or {text, style} tuples) or
  # a list of islands (elements are span lists).
  defp right_islands(nil), do: []

  defp right_islands(content) when is_list(content) do
    if Enum.all?(content, &(is_binary(&1) or match?({text, _style} when is_binary(text), &1))) do
      [content]
    else
      Enum.map(content, &as_spans/1)
    end
  end

  defp right_islands(content), do: [as_spans(content)]

  # `╰┘button└┘button└─────╯` — the bottom border doubles as the
  # buttonbar (position counters ride the TOP border's right island).
  # The bar elides right-to-left into the corner budget — trailing
  # buttons yield first — so the leftmost action keys and both corners
  # survive any width.
  defp bottom_row(width, buttons, border) do
    budget = width - 2
    bar = Enum.map(buttons, &as_spans!/1)
    {[], kept} = fit_border([], bar, budget)

    button_render =
      Enum.flat_map(kept, fn spans -> [{"┘", border}] ++ spans ++ [{"└", border}] end)

    used = 1 + content_width(button_render) + 1
    middle = String.duplicate("─", max(width - used, 0))

    [{"╰", border}] ++ button_render ++ [{middle, border}] ++ [{"╯", border}]
  end

  # Body rows clipped to the inner width, padded to the inner height;
  # BOTH side borders ride every row (the right border swaps to the
  # scrollbar glyphs while the content overflows) so the box's border
  # columns are identical on border and content rows at every width —
  # `│ content │` between the `╭`/`╮` and `╰`/`╯` columns.
  defp body_rows(rows, inner_w, inner_h, border, opts) do
    scrollbar = Keyword.get(opts, :scrollbar)
    thumb_style = Keyword.get(opts, :thumb_style, border)
    visible = Enum.take(rows, inner_h)
    padded = visible ++ List.duplicate([], max(inner_h - length(visible), 0))

    padded
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      right = right_border(index, inner_h, scrollbar, border, thumb_style)
      [{"│", border}] ++ Helpers.fit_row(row, inner_w) ++ right
    end)
  end

  # The right border of one body row: plain `│`, or the scrollbar glyph
  # while the content overflows (thumb in the accent-ish thumb style,
  # track and plain runs in the border style).
  defp right_border(index, inner_h, {offset, visible, total}, border, thumb_style)
       when total > visible do
    case scroll_glyph(index, inner_h, {offset, visible, total}) do
      "█" -> [{"█", thumb_style}]
      "▲" -> [{"▲", thumb_style}]
      "▼" -> [{"▼", thumb_style}]
      _track -> [{"▏", border}]
    end
  end

  defp right_border(_index, _inner_h, _scrollbar, border, _thumb_style), do: [{"│", border}]

  # `▲` above the thumb, `█` on the thumb, `▏` on the track, `▼` below it.
  defp scroll_glyph(index, inner_h, {offset, visible, total}) do
    thumb_size = max(div(visible * visible, total), 1)
    track = max(inner_h - 2, 1)
    thumb_start = div(offset * track, max(total - visible, 1)) + 1
    thumb_end = min(thumb_start + thumb_size - 1, track)

    cond do
      index == 0 and offset > 0 -> "▲"
      index == inner_h - 1 and offset + visible < total -> "▼"
      index >= thumb_start and index <= thumb_end -> "█"
      true -> "▏"
    end
  end

  defp as_spans(nil), do: nil
  defp as_spans(spans) when is_list(spans), do: spans
  defp as_spans(text) when is_binary(text), do: [{text, Style.new()}]

  defp as_spans!(content), do: as_spans(content) || []
end
