defmodule Workstation.CLI.TUI.Shell.TextView do
  @moduledoc """
  Scrollable plain-text pane behind the shell's read tabs (status, plan,
  diff): the canonical CLI render text (`Workstation.CLI.Render`), split to
  rows and scrolled with one shared key set. The pane is a pure view — the
  shell owns the keyboard and forwards the keys — so the TUI read views can
  never disagree with the verb output: both render the same function's text.
  """

  alias TermUI.Style
  alias TermUI.Widget.Helpers

  defstruct [:lines, :offset]

  @type t :: %__MODULE__{lines: [String.t()], offset: non_neg_integer()}

  @doc "Build one pane from rendered CLI text (newline-separated rows)."
  @spec init(String.t()) :: t()
  def init(text) when is_binary(text) do
    %__MODULE__{lines: String.split(text, "\n"), offset: 0}
  end

  @doc "Scroll keys; every other message is ignored (the shell filters first)."
  @spec update(term(), t()) :: t()
  def update({:key, :up}, t), do: scroll(t, -1)
  def update({:key, :down}, t), do: scroll(t, 1)
  def update({:key, :page_up}, t), do: scroll(t, -10)
  def update({:key, :page_down}, t), do: scroll(t, 10)
  def update({:key, :home}, t), do: %{t | offset: 0}
  def update({:key, :end}, t), do: %{t | offset: max(length(t.lines) - 1, 0)}
  def update(_message, t), do: t

  defp scroll(t, delta), do: %{t | offset: t.offset + delta |> max(0)}

  @doc "Render the visible window; the offset clamps to the data length."
  @spec view(t(), TermUI.Widget.dimensions()) :: TermUI.Frame.t()
  def view(%__MODULE__{lines: lines, offset: offset}, {width, height}) do
    offset = clamp(offset, 0, max(length(lines) - height, 0))

    rows =
      lines
      |> Enum.drop(offset)
      |> Enum.take(height)

    Helpers.frame(rows, {width, height})
  end

  @doc """
  Bordered read pane (btop border-as-buttonbar): the pane's action hints
  (scroll keys, refresh) ride the bottom border in the shortcut slot with
  a first-visible-line/total position counter, and the tab name titles
  the box.
  """
  @spec bordered_view(t(), TermUI.Widget.dimensions(), %{
          required(:title) => String.t(),
          required(:border) => Style.t(),
          required(:shortcut) => Style.t(),
          required(:chrome) => Style.t()
        }) :: TermUI.Frame.t()
  def bordered_view(%__MODULE__{lines: lines, offset: offset}, {width, height}, bar) do
    visible = inner_height(height)
    offset = clamp(offset, 0, max(length(lines) - visible, 0))

    rows =
      lines
      |> Enum.drop(offset)
      |> Enum.take(visible)

    box =
      Helpers.border(rows, {width, height}, title: bar.title, border_style: bar.border)

    bottom = buttonbar_row(width, offset, length(lines), bar)

    # Helpers.border/3 returns the full box; the bottom border becomes the
    # action bar (btop border-as-buttonbar).
    Helpers.frame(List.replace_at(box, -1, bottom), {width, height})
  end

  defp inner_height(height) when height > 2, do: height - 2
  defp inner_height(height), do: height

  # Bottom border rebuilt as the action bar: corner + fixed pad, the key
  # caps in the shortcut slot, the n/total counter flush right, closing
  # dash + corner. Span widths are measured so the row fills exactly.
  defp buttonbar_row(width, offset, total, bar) do
    hints = [
      {"↑↓", bar.shortcut},
      {" scroll", Style.new()},
      {" · ", bar.chrome},
      {"r", bar.shortcut},
      {" refresh", Style.new()}
    ]

    counter = {"#{offset + 1}/#{total}", bar.chrome}
    hints_width = spans_width(hints)
    counter_width = Helpers.text_width(elem(counter, 0))

    # 1 corner + 2 pad + hints + spacer + counter + 2 (dash + corner)
    spacer = max(width - hints_width - counter_width - 5, 1)

    [{"└", bar.border}, {String.duplicate("─", 2), bar.border}] ++
      hints ++
      [{String.duplicate(" ", spacer), bar.border}, counter, {"─┘", bar.border}]
  end

  defp spans_width(spans) do
    Enum.reduce(spans, 0, fn {text, _style}, acc -> acc + Helpers.text_width(text) end)
  end

  defp clamp(value, min, max), do: value |> max(min) |> min(max)
end
