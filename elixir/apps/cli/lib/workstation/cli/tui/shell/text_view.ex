defmodule Workstation.CLI.TUI.Shell.TextView do
  @moduledoc """
  Scrollable plain-text pane behind the shell's read tabs (status, plan,
  diff): the canonical CLI render text (`Workstation.CLI.Render`), split to
  rows and scrolled with one shared key set. The pane is a pure view — the
  shell owns the keyboard and forwards the keys — so the TUI read views can
  never disagree with the verb output: both render the same function's text.
  """

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

  defp clamp(value, min, max), do: value |> max(min) |> min(max)
end
