defmodule Workstation.Core.Theme.TokensTest do
  use ExUnit.Case, async: true

  alias Workstation.Core.Theme.Tokens

  test "the engine token set carries the same contract values as the theme payload" do
    # Cross-carrier consistency: modules/theme/tokens.lua (the managed-tree
    # payload) must carry identical values. The token set names no consumer;
    # consumer choices live in the consumers' own modules.
    assert Tokens.version() == 4

    assert Map.new(Tokens.slots()) == %{
             accent: "blue",
             ok: "green",
             warn: "yellow",
             err: "red",
             chrome: "brightblack",
             text: "white",
             shortcut: "magenta",
             selected_bg: "brightblack",
             selected_fg: "white",
             inactive: "brightblack",
             ramp_start: "green",
             ramp_mid: "yellow",
             ramp_end: "red",
             border_engine: "blue",
             border_journal: "green",
             border_capabilities: "yellow",
             border_plan: "blue",
             border_diff: "red",
             border_status: "green"
           }
  end

  test "palette carries all twenty-one roles for both appearances" do
    # The role set is the envelope schema; a dropped role silently
    # vanishes from every rendered envelope.
    roles = [
      :accent,
      :ok,
      :warn,
      :err,
      :chrome,
      :text,
      :shortcut,
      :selected_bg,
      :selected_fg,
      :inactive,
      :ramp_start,
      :ramp_mid,
      :ramp_end,
      :border_engine,
      :border_journal,
      :border_capabilities,
      :border_plan,
      :border_diff,
      :border_status,
      :bg,
      :muted
    ]

    for appearance <- [:dark, :light] do
      palette = Tokens.palette(appearance)

      assert Enum.sort(Keyword.keys(palette)) == Enum.sort(roles)

      for {role, hex} <- palette do
        assert Regex.match?(~r/\A#[0-9a-fA-F]{6}\z/, hex), "role #{appearance}/#{role} is not #rrggbb: #{inspect(hex)}"
      end
    end
  end
end
