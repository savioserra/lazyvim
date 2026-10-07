defmodule Workstation.CLI.TUI.Shell.Box do
  @moduledoc """
  btop box anatomy — the one builder every boxed pane goes through.

  The screen body is a mosaic of adjacent rounded boxes on the terminal
  background (no filled panels). Each box owns its border chrome:

    * the title is an ISLAND inside the top border run, opened by `┐` and
      closed by `┌`: `╭─┐3 status┌──────────`; the keycap digit rides the
      shortcut slot inside the island (the caller styles the spans);
    * an optional right island on the top border carries counters/badges:
      `──────┐2/41┌─╮`;
    * the bottom border doubles as the box's buttonbar — buttons are
      `┘label└` islands, the position counter is the last island:
      `╰┘↑↓ scroll└┘r refresh└────┘1/41└╯`;
    * on overflow the right border becomes a block scrollbar
      (`▲` above, `█` thumb, `▏` track, `▼` below) hugging the border.

  Boxes are pure Frame builders over span rows, so deterministic frame
  tests (pinned wires, no daemon) assert the anatomy cell-by-cell. All
  colors arrive as theme-role styles from the caller — this module never
  hardcodes one.
  """

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
    * `:counter` — final bottom-border island content (position counter)
    * `:scrollbar` — `{offset, visible, total}`; swaps the right border to
      the block scrollbar while the content overflows
    * `:thumb_style` — scrollbar thumb style (default: the border style)
  """
  @spec frame([row()], TermUI.Widget.dimensions(), keyword()) :: Frame.t()
  def frame(rows, {width, height}, opts) do
    border = Keyword.get(opts, :border_style, Style.new())
    inner_w = max(width - 2, 0)
    inner_h = max(height - 2, 0)

    top = top_row(width, Keyword.get(opts, :title), Keyword.get(opts, :right), border)
    bottom = bottom_row(width, Keyword.get(opts, :buttons, []), Keyword.get(opts, :counter), border)
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
  # can ride the border as separate islands.
  defp top_row(width, title, right, border) do
    left =
      case as_spans(title) do
        nil -> []
        spans -> [{"─┐", border}] ++ spans ++ [{"┌", border}]
      end

    islands = right_islands(right)

    right_islands_render =
      islands
      |> Enum.flat_map(fn spans -> [{"┐", border}] ++ spans ++ [{"┌", border}] end)
      |> Kernel.++(if islands == [], do: [], else: [{"─", border}])

    used = 1 + content_width(left) + content_width(right_islands_render) + 1

    middle = String.duplicate("─", max(width - used, 0))

    [{"╭", border}] ++ left ++ [{middle, border}] ++ right_islands_render ++ [{"╮", border}]
  end

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

  # `╰┘button└┘button└────┘1/41└╯` — the bottom border doubles as the
  # buttonbar; the position counter is the last island before the corner.
  defp bottom_row(width, buttons, counter, border) do
    button_islands =
      Enum.flat_map(buttons, fn button ->
        [{"┘", border}] ++ as_spans!(button) ++ [{"└", border}]
      end)

    counter_island =
      case as_spans(counter) do
        nil -> []
        spans -> [{"┘", border}] ++ spans ++ [{"└", border}]
      end

    used = 1 + content_width(button_islands) + content_width(counter_island) + 1
    middle = String.duplicate("─", max(width - used, 0))

    [{"╰", border}] ++ button_islands ++ [{middle, border}] ++ counter_island ++ [{"╯", border}]
  end

  # Body rows clipped to the inner width, padded to the inner height; the
  # trailing span of every row is the right border (or the scrollbar glyph
  # while the content overflows).
  defp body_rows(rows, inner_w, inner_h, border, opts) do
    scrollbar = Keyword.get(opts, :scrollbar)
    thumb_style = Keyword.get(opts, :thumb_style, border)
    visible = Enum.take(rows, inner_h)
    padded = visible ++ List.duplicate([], max(inner_h - length(visible), 0))

    padded
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      right = right_border(index, inner_h, scrollbar, border, thumb_style)
      Helpers.fit_row(row, inner_w) ++ right
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
