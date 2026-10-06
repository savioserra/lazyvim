defmodule Workstation.Core.Theme.TokensTest do
  use ExUnit.Case, async: true

  alias Workstation.Core.Theme.Tokens

  # The parity anchor lives in the repo's goldens tree (shared with the Lua
  # engine's b2 goldens): from __DIR__ (apps/core/test/workstation/core/theme)
  # it is seven levels up to the repo root.
  @goldens Path.expand("../../../../../../../tests/goldens/theme/input.json", __DIR__)

  defp fixture_theme_bytes do
    assert File.exists?(@goldens), "theme goldens fixture missing at #{@goldens} — the parity anchor must run"

    fixture = @goldens |> File.read!() |> Jason.decode!()

    theme_package = Enum.find(fixture["packages"], &(&1["id"] == "theme")) || flunk("theme package missing from the goldens fixture")

    contribution =
      Enum.find(theme_package["contributes"], &(&1["provider"] == "chezmoi-data")) ||
        flunk("chezmoi-data contribution missing from the theme goldens fixture")

    contribution["spec"]["content"]
  end

  test "chezmoidata/0 is byte-identical to the engine's rendered theme envelope" do
    assert Tokens.chezmoidata() == fixture_theme_bytes()
  end

  test "the mirror carries the same contract values as tokens.lua" do
    # Parity anchor: packages/theme/tokens.lua must carry identical values.
    assert Tokens.version() == 2
    assert Tokens.herdr_consumer() == %{name: "terminal", auto_switch: true}

    assert Map.new(Tokens.slots()) == %{
             accent: "blue",
             ok: "green",
             warn: "yellow",
             err: "red",
             chrome: "brightblack",
             text: "black",
             shortcut: "magenta",
             selected_bg: "blue",
             selected_fg: "black",
             inactive: "brightblack",
             ramp_start: "green",
             ramp_mid: "yellow",
             ramp_end: "red"
           }
  end

  test "palette carries all fifteen roles for both appearances" do
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

  test "every palette role is settable by a theme overlay" do
    # Roles-are-the-API: the overlay patch surface (Core.Theme.settable_roles)
    # must cover the whole declared palette, or an envelope role becomes
    # unpatchable and the API silently narrows.
    settable = MapSet.new(Workstation.Core.Theme.settable_roles())

    for {role, _hex} <- Tokens.palette(:dark) do
      assert MapSet.member?(settable, Atom.to_string(role)), "palette role #{role} is not overlay-settable"
    end
  end
end
