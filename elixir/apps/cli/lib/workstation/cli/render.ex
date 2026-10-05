defmodule Workstation.CLI.Render do
  @moduledoc """
  Plain-text rendering of the hard-cut core wire schemas
  (`workstation.status.v1`, `workstation.plan.v1`, `workstation.diff.v1`).

  Non-TTY output is always plain text; this module is deliberately
  terminal-free so output is stable under redirection and in tests. Input
  wires are produced by `Workstation.CLI.Core` (the only front end since the
  b8 graduation flip). Field order is fixed or positional, so identical
  evaluation state renders identical text; the plan view mirrors the
  `changesets.lua M.print_report` anchor layout, and the Lua-side parity of
  that layout is pinned by tests/goldens plus the b8 old-vs-new harness.
  """

  ## core wire views (workstation.{status,plan,diff}.v1, lane b5)

  # The hard-cut v1 wires carry the fields below, so they render through
  # their own views. The plan view mirrors
  # `changesets.lua M.print_report` (sections and layout); the two documented
  # deviations keep the wire the single source of truth: the header names the
  # front end instead of the destination (the plan.v1 envelope deliberately
  # does not carry the home path — destination is a status-wire field), and
  # modes print as the wire's canonical octal strings rather than being
  # re-derived. Patches without a text diff print their typed header without
  # the anchor's duplicated `link` suffix (a Lua format-string quirk).
  @doc "Render the hard-cut core status wire (`workstation.status.v1`)."
  def core_status(wire) do
    packages =
      case Enum.map(Map.get(wire, "packages", []), &Map.get(&1, "id")) do
        [] -> "none"
        ids -> Enum.join(ids, ", ")
      end

    journal_line =
      case Map.get(wire, "journal") do
        nil ->
          "journal: none"

        journal ->
          "journal: generation=#{journal["generation"]} revision=#{render_value(journal["revision"])}" <>
            maybe_at(journal)
      end

    join([
      "workstation status (core)",
      "platform: #{Map.get(wire, "platform", "?")}",
      "packages: #{packages}",
      "graph_order: #{render_value(Map.get(wire, "graph_order", []))}",
      "destination: #{Map.get(wire, "destination", "?")}",
      journal_line
    ])
  end

  defp render_value(value) when is_binary(value), do: value
  defp render_value(value), do: inspect(value, pretty: false, limit: 20)

  defp join(lines) do
    lines
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp maybe_at(journal) do
    case Map.get(journal, "at") do
      nil -> ""
      at -> " at=#{render_value(at)}"
    end
  end

  @doc """
  Render the hard-cut core plan wire (`workstation.plan.v1`) as the human
  plan preview, mirroring `changesets.lua M.print_report`.
  """
  def core_plan(wire) do
    plan = Map.get(wire, "plan", %{})
    entries = Map.get(plan, "entries", [])
    removals = Map.get(plan, "removals", [])
    unsupported = Map.get(plan, "unsupported_reversals", [])
    states = Map.get(wire, "target_states", %{})

    baseline_line =
      case Map.get(plan, "baseline_generation") do
        nil ->
          "  baseline   : none (initial plan; every source entry is an addition)"

        generation ->
          "  baseline   : #{generation} (verified against the journaled manifest)"
      end

    unsupported_lines =
      if unsupported == [] do
        []
      else
        ["  unsupported reversals (arbitrary whole-body modifiers; clean up explicitly):"] ++
          Enum.map(unsupported, fn reversal ->
            "    #{reversal["target"]} (was owned by #{reversal["owner"]})"
          end)
      end

    target_lines =
      Enum.map(entries, &target_line(&1["target"], states, "")) ++
        Enum.map(removals, &target_line(&1["target"], states, " (removal)"))

    patch_lines = Enum.map(Map.get(wire, "patches", []), &render_patch/1)

    join([
      "workstation plan (core)",
      "  generation : #{Map.get(wire, "generation", "?")}",
      "  entries    : #{length(entries)}  removals: #{length(removals)}",
      baseline_line,
      Enum.map(entries, &changeset_line/1),
      unsupported_lines,
      target_lines,
      patch_lines,
      "plan complete."
    ])
  end

  defp changeset_line(record) do
    attributes =
      Enum.reject(
        [
          record["type"],
          record["mode"] && "mode #{unpadded_octal(record["mode"])}",
          record["link"] && "link #{record["link"]}"
        ],
        &is_nil/1
      )

    owners =
      case Map.get(record, "attribution") do
        owners when is_list(owners) and owners != [] -> Enum.join(owners, ",")
        _ -> record["owner"] || "?"
      end

    source = record["name"] || record["source"] || "-"

    "  #{record["operation"]} #{source} -> #{record["target"]} " <>
      "[#{Enum.join(attributes, " ")}] owner #{owners}" <>
      if(record["shared"], do: " (shared)", else: "")
  end

  defp unpadded_octal(mode) when is_binary(mode) do
    case Integer.parse(mode, 8) do
      {value, ""} -> Integer.to_string(value, 8)
      _ -> mode
    end
  end

  defp unpadded_octal(mode), do: render_value(mode)

  defp target_line(target, states, suffix) do
    "  target #{String.pad_trailing(target, 45)} #{Map.get(states, target, "?")}#{suffix}"
  end

  # Patch bodies print verbatim (raw diff bytes, like the anchor's io.write);
  # typed metadata prints its attributed header line.
  defp render_patch(patch) do
    case Map.get(patch, "diff") do
      diff when is_binary(diff) and diff != "" ->
        String.trim_trailing(diff, "\n")

      _ ->
        attributes =
          Enum.reject(
            [
              patch["type"],
              patch["mode"] && "mode #{patch["mode"]}",
              patch["link"] && "link #{patch["link"]}"
            ],
            &is_nil/1
          )

        owners =
          case Map.get(patch, "attribution") do
            owners when is_list(owners) and owners != [] -> Enum.join(owners, ",")
            _ -> patch["owner"] || "?"
          end

        "# #{patch["kind"]} #{patch["source"]} (#{Enum.join(attributes, " ")}, owner #{owners})"
    end
  end

  @doc "Render the hard-cut core diff wire (`workstation.diff.v1`)."
  def core_diff(wire) do
    records = Map.get(wire, "backend_diff", [])

    join([
      "workstation diff (core)",
      if(records == [], do: "no differences", else: nil),
      Enum.map(records, &changeset_line/1)
    ])
  end
end
