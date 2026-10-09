defmodule Workstation.Core.Theme.TokensTest do
  use ExUnit.Case, async: true

  alias Workstation.Core.Theme.Tokens

  # The anchor fixture lives in the repo's goldens tree: from __DIR__
  # (apps/core/test/workstation/core/theme) it is seven levels up to the
  # repo root.
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

  test "data_envelope/0 is byte-identical to the engine's rendered theme envelope" do
    assert Tokens.data_envelope() == fixture_theme_bytes()
  end

  test "the engine token set carries the same contract values as the theme payload" do
    # Cross-carrier consistency: packages/theme/tokens.lua (the managed-tree
    # payload) must carry identical values. The token set names no consumer
    # package; consumer choices live in the consumers' own package modules
    # (see the herdr catalog module).
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
