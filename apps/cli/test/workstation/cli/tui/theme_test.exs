defmodule Workstation.CLI.TUI.ThemeTest do
  use ExUnit.Case, async: true

  alias Workstation.CLI.TUI.Theme
  alias Workstation.Core.Theme.Tokens

  test "base path mirrors the core tokens palette exactly" do
    assert Theme.base_colors(:dark) == Map.new(Tokens.palette(:dark))
    assert Theme.base_colors(:light) == Map.new(Tokens.palette(:light))

    assert Map.keys(Theme.base_colors(:dark)) |> Enum.sort() ==
             [
               :accent,
               :bg,
               :border_capabilities,
               :border_diff,
               :border_engine,
               :border_journal,
               :border_plan,
               :border_status,
               :chrome,
               :err,
               :inactive,
               :muted,
               :ok,
               :ramp_end,
               :ramp_mid,
               :ramp_start,
               :selected_bg,
               :selected_fg,
               :shortcut,
               :text,
               :warn
             ]
             |> Enum.sort()
  end

  test "resolve answers the base palette, dark by default and light on request" do
    resolution = Theme.resolve([])

    assert resolution.source == :base
    assert resolution.colors == Theme.base_colors(:dark)

    light = Theme.resolve(appearance: :light)

    assert light.source == :base
    assert light.colors == Theme.base_colors(:light)
  end

  test "to_term_ui_color converts #rrggbb and refuses every other shape" do
    assert Theme.to_term_ui_color("#89b4fa") == {:rgb, 0x89, 0xB4, 0xFA}
    assert Theme.to_term_ui_color("#000000") == {:rgb, 0, 0, 0}
    assert Theme.to_term_ui_color("89b4fa") == nil
    assert Theme.to_term_ui_color("#89b4") == nil
    assert Theme.to_term_ui_color("#zzzzzz") == nil
    assert Theme.to_term_ui_color(:cyan) == nil
  end
end
