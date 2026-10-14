defmodule Workstation.CLI.TUI.Shell.TextView do
  @moduledoc """
  Scrollable plain-text pane behind the shell's in-box deep views (the
  plan/diff read zooms) and help: the canonical CLI render text
  (`Workstation.CLI.Render`), split to rows and scrolled with one shared
  key set. The pane is a pure view — the shell owns the keyboard and
  forwards the keys — so the TUI read views can never disagree with the
  verb output: both render the same function's text.

  The pane renders as one btop box (`Shell.Box`): the tab name titles the
  border as an island, the bottom border doubles as the action bar (scroll
  and refresh buttons, first-visible-line/total position counter), and an
  overflowing pane gets the block scrollbar on the right border.
  """

  alias TermUI.Style
  alias TermUI.Widget.Helpers
  alias Workstation.CLI.TUI.Shell.Box

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
  Boxed read pane (btop anatomy): the box title island carries the box
  digit + name, `:right` renders extra islands on the top border, the
  position counter rides the TITLE border's right island — after any
  `:right` badge, and only while the pane overflows one page (a
  single-page list carries no counter, never a mid-border island) — the
  bottom border is the action bar (`↑↓ scroll` and `r refresh` buttons)
  and overflow rides the right-border block scrollbar.
  """
  @spec bordered_view(t(), TermUI.Widget.dimensions(), %{
          required(:title) => term(),
          required(:border) => Style.t(),
          required(:shortcut) => Style.t(),
          required(:chrome) => Style.t(),
          optional(:right) => term(),
          optional(:thumb) => Style.t()
        }) :: TermUI.Frame.t()
  def bordered_view(%__MODULE__{lines: lines, offset: offset}, {width, height}, bar) do
    visible = inner_height(height)
    offset = clamp(offset, 0, max(length(lines) - visible, 0))

    rows =
      lines
      |> Enum.drop(offset)
      |> Enum.take(visible)

    Box.frame(rows, {width, height},
      border_style: bar.border,
      title: bar.title,
      right: title_counter(offset, length(lines), visible, bar),
      buttons: [
        [{"↑↓", bar.shortcut}, {" scroll", bar.chrome}],
        [{"r", bar.shortcut}, {" refresh", bar.chrome}]
      ],
      scrollbar: {offset, visible, length(lines)},
      thumb_style: Map.get(bar, :thumb, bar.shortcut)
    )
  end

  # The position counter rides the TITLE border's right island — never a
  # mid-border island — and only while the pane overflows one page: a
  # single-page list carries no counter (a "1/1" island is noise). The
  # caller's `:right` badge (e.g. the journal revision) comes first.
  defp title_counter(_offset, total, visible, bar) when total <= visible,
    do: Map.get(bar, :right)

  defp title_counter(offset, total, _visible, bar) do
    (Map.get(bar, :right) || []) ++ [{"#{offset + 1}/#{total}", bar.chrome}]
  end

  defp inner_height(height) when height > 2, do: height - 2
  defp inner_height(height), do: height

  defp clamp(value, min, max), do: value |> max(min) |> min(max)
end
