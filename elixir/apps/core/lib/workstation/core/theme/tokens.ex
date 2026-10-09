defmodule Workstation.Core.Theme.Tokens do
  @moduledoc """
  The engine-side carrier of the workstation theme token set — the palette
  the daemon serves to live clients.

  The token set has exactly two carriers that must agree value-for-value:
  this module (in-process resolution for the daemon) and
  `workstation/packages/theme/tokens.lua` (the managed-tree payload, read as
  bytes, never executed). The duplication is deliberate and reviewed, with
  an ExUnit consistency anchor
  (`apps/core/test/workstation/core/theme/tokens_test.exs`) that compares the
  rendered `.chezmoidata.toml` envelope byte-for-byte against the committed
  theme goldens fixture (`tests/goldens/theme/input.json`). Re-branding edits
  BOTH carriers and re-records the goldens; a stale carrier fails the
  consistency test instead of silently serving stale colors.

  Layers (identical in both carriers):

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

  The token set names no consumer package: consumers derive their own
  artifacts from these roles (templates read the rendered envelope), and a
  consumer's own choices live in the consumer's package, never here.

  Roles are the API, values are data: no consumer may hardcode a literal
  color for a role carried here.
  """

  # Brand: Starlight (upstream starlight @thm_* token names); dark from
  # themes/dark/oasis_starlight_dark.conf, light from the light_3 sibling
  # (upstream default intensity). Judgment calls per rebrand spec S-R3.
  @version 4

  # Ordered lists drive every emission; maps are only storage. The rendered
  # bytes are pinned (goldens + the consistency test), so traversal order is
  # never delegated to map iteration. New roles append after the base six:
  # keyboard/selection affordances (shortcut, selected pair, inactive), the
  # magnitude ramp trio start->mid->end, then the per-domain border roles.
  @slot_roles [:accent, :ok, :warn, :err, :chrome, :text, :shortcut, :selected_bg, :selected_fg, :inactive, :ramp_start, :ramp_mid, :ramp_end, :border_engine, :border_journal, :border_capabilities, :border_plan, :border_diff, :border_status]
  @palette_roles [:accent, :ok, :warn, :err, :chrome, :text, :shortcut, :selected_bg, :selected_fg, :inactive, :ramp_start, :ramp_mid, :ramp_end, :border_engine, :border_journal, :border_capabilities, :border_plan, :border_diff, :border_status, :bg, :muted]
  @appearances [:dark, :light]
  # The closed set of border roles a consumer may request for a panel
  # border. Consumers validate against this list (`role in border_roles()`),
  # never against a wider set — a typo fails closed instead of silently
  # falling back to the accent default.
  @border_roles [:border_engine, :border_journal, :border_capabilities, :border_plan, :border_diff, :border_status]

  @slots %{
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

  @palette %{
    dark: %{
      accent: "#5badff",
      ok: "#7fcf78",
      warn: "#f0e68c",
      err: "#ff7979",
      chrome: "#4f5b6b",
      text: "#f5f5dc",
      shortcut: "#c695ff",
      selected_bg: "#4d4528",
      selected_fg: "#f5f5dc",
      inactive: "#4f5b6b",
      ramp_start: "#7fcf78",
      ramp_mid: "#f0e68c",
      ramp_end: "#ff7979",
      border_engine: "#5badff",
      border_journal: "#7fcf78",
      border_capabilities: "#f0e68c",
      border_plan: "#5badff",
      border_diff: "#ff7979",
      border_status: "#7fcf78",
      bg: "#000000",
      muted: "#666666"
    },
    light: %{
      accent: "#023c75",
      ok: "#3b6837",
      warn: "#665f22",
      err: "#bc1313",
      chrome: "#50463e",
      text: "#181811",
      shortcut: "#7d2adc",
      selected_bg: "#e1d8c1",
      selected_fg: "#181811",
      inactive: "#50463e",
      ramp_start: "#3b6837",
      ramp_mid: "#665f22",
      ramp_end: "#bc1313",
      border_engine: "#023c75",
      border_journal: "#3b6837",
      border_capabilities: "#665f22",
      border_plan: "#023c75",
      border_diff: "#bc1313",
      border_status: "#3b6837",
      bg: "#f5f2ea",
      muted: "#50463e"
    }
  }

  @doc "Token set version; bumped in both carriers when the shape changes."
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

  @doc """
  Closed set of border roles (atoms) a consumer may request for a panel
  border; consumers validate membership explicitly.
  """
  @spec border_roles() :: [atom()]
  def border_roles, do: @border_roles

  @doc """
  Deterministic TOML rendering of the whole token set as the engine's
  data-envelope contribution (the backend installs it as its source-root
  data file, whose filename is the backend module's contract). The engine
  merges it at the template-data top level, so templates read
  `{{ .theme.slots.accent }}` and `{{ .theme.palette.dark.accent }}`.
  Regenerated, never patched.
  """
  @spec data_envelope() :: String.t()
  def data_envelope do
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
        ""
      ]
      |> Enum.intersperse("\n")
      |> IO.iodata_to_binary()
  end

  # Token values are plain, non-empty and control-byte-free; quoting and
  # backslash escaping is unnecessary for the closed token set, but the
  # guard stays so a bad carrier edit fails loudly instead of emitting
  # broken TOML.
  defp toml_string(value) when is_binary(value) do
    unless value != "" and not String.contains?(value, ["\\", "\""]) and
             not String.match?(value, ~r/[\x00-\x1f\x7f]/) do
      raise ArgumentError, "theme token value must be a plain token: #{inspect(value)}"
    end

    "\"" <> value <> "\""
  end
end
