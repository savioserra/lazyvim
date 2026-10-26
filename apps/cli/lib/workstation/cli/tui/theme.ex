defmodule Workstation.CLI.TUI.Theme do
  @moduledoc """
  Palette resolution for the workstation TUI.

  docs/theme.md pins term_ui as a `palette`-layer consumer: it cannot follow
  the live terminal palette through OSC 4 retints, so the shell needs
  concrete `#rrggbb` colors and never terminal slot names. Resolution is the
  base token palette (`Workstation.Core.Theme.Tokens.palette/1`, the engine
  carrier of the token set alongside the deployed
  `modules/theme/tokens.lua` payload) — the same bytes the nix theme module
  deploys to the store token path (`~/.local/state/workstation/theme.json`,
  refreshed by every switch for consumers that read the file).

  The daemon's `theme.resolve` overlay path retired with the daemon: no
  overlay state survives outside a switch, so the base palette is the whole
  resolution. Appearance is explicit (`:dark` default) and never silently
  switched.

  Slot names are deliberately absent here: a palette-layer consumer would
  render them as literals, which is exactly the drift docs/theme.md forbids.
  """

  alias Workstation.Core.Theme.Tokens

  @default_appearance :dark

  @type role ::
          :accent
          | :ok
          | :warn
          | :err
          | :chrome
          | :text
          | :shortcut
          | :selected_bg
          | :selected_fg
          | :inactive
          | :ramp_start
          | :ramp_mid
          | :ramp_end
          | :border_engine
          | :border_journal
          | :border_capabilities
          | :border_plan
          | :border_diff
          | :border_status
          | :bg
          | :muted
  @type colors :: %{optional(role()) => String.t()}
  @type resolution :: %{colors: colors(), source: :base}

  @doc """
  Resolve one palette: the base token palette of the requested appearance.

  Options:

    * `:appearance` — `:dark` (default) or `:light`; resolution never
      silently switches appearance.
  """
  @spec resolve(keyword()) :: resolution()
  def resolve(opts \\ []) do
    appearance = Keyword.get(opts, :appearance, @default_appearance)
    %{colors: base_colors(appearance), source: :base}
  end

  @doc "Base token palette of one appearance, atom-keyed."
  @spec base_colors(atom() | String.t()) :: colors()
  def base_colors(appearance), do: Map.new(Tokens.palette(appearance))

  @doc """
  `#rrggbb` to a term_ui RGB style color; any other shape is nil so callers
  skip the tint instead of guessing.
  """
  @spec to_term_ui_color(term()) :: {:rgb, 0..255, 0..255, 0..255} | nil
  def to_term_ui_color("#" <> <<r::binary-size(2), g::binary-size(2), b::binary-size(2)>>) do
    with {{r, ""}, {g, ""}, {b, ""}} <-
           {Integer.parse(r, 16), Integer.parse(g, 16), Integer.parse(b, 16)} do
      {:rgb, r, g, b}
    else
      _ -> nil
    end
  end

  def to_term_ui_color(_other), do: nil
end
