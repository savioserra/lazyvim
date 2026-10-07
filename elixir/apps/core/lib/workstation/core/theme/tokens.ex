defmodule Workstation.Core.Theme.Tokens do
  @moduledoc """
  Elixir data mirror of the canonical theme token module
  `workstation/packages/theme/tokens.lua` — the single place where
  workstation colors are defined.

  Why this mirror exists: the daemon answers `theme.resolve` requests from
  live clients, so the resolution base (the palette) must be available to
  the Elixir side without shelling out to Neovim. It is a deliberate,
  reviewed duplication with an ExUnit parity anchor
  (`apps/core/test/workstation/core/theme/tokens_test.exs`) that compares the
  rendered `.chezmoidata.toml` envelope byte-for-byte against the committed
  theme goldens fixture (`tests/goldens/theme/input.json`). Re-branding still
  edits ONLY `tokens.lua`; a mirror that has not been updated fails the
  parity test instead of silently serving stale colors.

  Layers (same contract as the Lua module):

  * `slots`   — role -> terminal NAMED palette slot, appearance-agnostic
                (consumers that resolve named slots follow the live terminal
                palette through OSC 4 retints);
  * `palette` — role -> concrete `#rrggbb` color per appearance, for
                consumers that cannot follow the terminal;
  * `border_roles` — the closed set of dashboard border roles, one per
                panel domain: `border_engine`/`border_plan` (blue, the
                engine-core forward views), `border_journal`/
                `border_status` (green, health-log semantics),
                `border_capabilities` (yellow, pending-apply caution),
                `border_diff` (red, the mutation surface). Values reuse
                existing palette hues — no new colors.
  * `consumers` — canonical choices for surfaces the engine documents but
                deliberately does not reconfigure (`herdr` owns its live
                config.toml).

  Roles are the API, values are data: no consumer may hardcode a literal
  color for a role carried here.
  """

  @version 3

  # Ordered lists drive every emission; maps are only storage. The rendered
  # bytes must equal the Lua renderer's output, so traversal order is never
  # delegated to map iteration. New roles append after the base six:
  # keyboard/selection affordances (shortcut, selected pair, inactive), the
  # magnitude ramp trio start->mid->end, then the per-domain border roles.
  @slot_roles [:accent, :ok, :warn, :err, :chrome, :text, :shortcut, :selected_bg, :selected_fg, :inactive, :ramp_start, :ramp_mid, :ramp_end, :border_engine, :border_journal, :border_capabilities, :border_plan, :border_diff, :border_status]
  @palette_roles [:accent, :ok, :warn, :err, :chrome, :text, :shortcut, :selected_bg, :selected_fg, :inactive, :ramp_start, :ramp_mid, :ramp_end, :border_engine, :border_journal, :border_capabilities, :border_plan, :border_diff, :border_status, :bg, :muted]
  @appearances [:dark, :light]

  # The closed set of border roles a consumer may request for a panel
  # border. Mirrors the Lua module; consumers validate against this list
  # (`role in border_roles()`), never against a wider set — a typo fails
  # closed instead of silently falling back to the accent default.
  @border_roles [:border_engine, :border_journal, :border_capabilities, :border_plan, :border_diff, :border_status]

  @slots %{
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
    ramp_end: "red",
    border_engine: "blue",
    border_journal: "green",
    border_capabilities: "yellow",
    border_plan: "blue",
    border_diff: "red",
    border_status: "green"
  }

  @palette %{
    dark: %{
      accent: "#7aa2f7",
      ok: "#9ece6a",
      warn: "#e0af68",
      err: "#f7768e",
      chrome: "#414868",
      text: "#c0caf5",
      shortcut: "#bb9af7",
      selected_bg: "#292e42",
      selected_fg: "#c0caf5",
      inactive: "#565f89",
      ramp_start: "#9ece6a",
      ramp_mid: "#e0af68",
      ramp_end: "#f7768e",
      border_engine: "#7aa2f7",
      border_journal: "#9ece6a",
      border_capabilities: "#e0af68",
      border_plan: "#7aa2f7",
      border_diff: "#f7768e",
      border_status: "#9ece6a",
      bg: "#1a1b26",
      muted: "#565f89"
    },
    light: %{
      accent: "#2e7de9",
      ok: "#587539",
      warn: "#8c6c3e",
      err: "#f52a65",
      chrome: "#a1a6c5",
      text: "#3760bf",
      shortcut: "#7847bd",
      selected_bg: "#cfdaf5",
      selected_fg: "#3760bf",
      inactive: "#6172b0",
      ramp_start: "#587539",
      ramp_mid: "#8c6c3e",
      ramp_end: "#f52a65",
      border_engine: "#2e7de9",
      border_journal: "#587539",
      border_capabilities: "#8c6c3e",
      border_plan: "#2e7de9",
      border_diff: "#f52a65",
      border_status: "#587539",
      bg: "#e1e2e7",
      muted: "#6172b0"
    }
  }

  @consumers %{herdr: %{name: "terminal", auto_switch: true}}

  @doc "Token set version; bumped by the Lua module when the shape changes."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "role -> terminal named slot, in canonical emission order."
  @spec slots() :: [{atom(), String.t()}]
  def slots, do: Enum.map(@slot_roles, &{&1, Map.fetch!(@slots, &1)})

  @doc """
  Resolved palette for one appearance: ordered `role -> #rrggbb` pairs.
  Raises on an unknown appearance — callers never fall back to another
  appearance, they reject the request.
  """
  @spec palette(atom() | String.t()) :: [{atom(), String.t()}]
  def palette(appearance) when is_atom(appearance) and appearance in @appearances,
    do: @palette |> Map.fetch!(appearance) |> then(fn map -> Enum.map(@palette_roles, &{&1, Map.fetch!(map, &1)}) end)

  # The daemon domain calls with wire appearances (binaries). to_existing_atom
  # is safe: the atom set is the module's own closed @appearances pair, so a
  # foreign binary can never mint an atom here.
  def palette(appearance) when is_binary(appearance), do: palette(String.to_existing_atom(appearance))

  @doc "The herdr consumer choice: which layer it consumes and whether it auto-switches."
  @spec herdr_consumer() :: %{name: String.t(), auto_switch: boolean()}
  def herdr_consumer, do: @consumers.herdr

  @doc """
  Closed set of border roles (atoms) a consumer may request for a panel
  border; consumers validate membership explicitly.
  """
  @spec border_roles() :: [atom()]
  def border_roles, do: @border_roles

  @doc """
  Deterministic TOML rendering of the whole token set as the source-root
  `.chezmoidata.toml` envelope, byte-identical to
  `tokens.lua` `M.chezmoidata()`. chezmoi merges this file at the
  template-data top level, so templates read `{{ .theme.slots.accent }}` and
  `{{ .theme.palette.dark.accent }}`. Regenerated, never patched.
  """
  @spec chezmoidata() :: String.t()
  def chezmoidata do
    [
      "# Generated by the workstation theme capability (packages/theme/tokens.lua).",
      "# Canonical engine roles in two layers: terminal slots for consumers",
      "# that follow the live terminal palette, concrete colors per appearance",
      "# for consumers that cannot. This file is regenerated, never patched.",
      "version = #{Integer.to_string(@version)}",
      "",
      "[theme.slots]"
    ] ++
      Enum.map(slots(), fn {role, slot} -> "#{role} = #{toml_string(slot)}" end) ++
      Enum.flat_map(@appearances, fn appearance ->
        ["", "[theme.palette.#{Atom.to_string(appearance)}]"] ++
          Enum.map(palette(appearance), fn {role, hex} -> "#{role} = #{toml_string(hex)}" end)
      end) ++
      [
        "",
        "[theme.consumers.herdr]",
        "name = #{toml_string(@consumers.herdr.name)}",
        "auto_switch = #{Atom.to_string(@consumers.herdr.auto_switch)}",
        ""
      ]
      |> Enum.intersperse("\n")
      |> IO.iodata_to_binary()
  end

  # Mirrors the Lua toml_string: plain, non-empty, no control bytes, quotes
  # and backslashes escaped is unnecessary for the closed token set, but the
  # guard stays so a bad mirror edit fails loudly instead of emitting broken
  # TOML.
  defp toml_string(value) when is_binary(value) do
    unless value != "" and not String.contains?(value, ["\\", "\""]) and
             not String.match?(value, ~r/[\x00-\x1f\x7f]/) do
      raise ArgumentError, "theme token value must be a plain token: #{inspect(value)}"
    end

    "\"" <> value <> "\""
  end
end
