defmodule Workstation.CLI.Render do
  @moduledoc """
  Plain-text rendering of the hard-cut core wire schemas
  (`workstation.status.v1`, `workstation.plan.v1`, `workstation.diff.v1`).

  Non-TTY output is always plain text; this module is deliberately
  terminal-free so output is stable under redirection and in tests. Input
  wires are produced by `Workstation.CLI.Core` (the only front end since the
  b8 graduation flip). Field order is fixed or positional, so identical
  evaluation state renders identical text; the plan view layout is pinned
  by the committed goldens.
  """

  ## core wire views (workstation.{status,plan,diff}.v1, lane b5)

  # The hard-cut v1 wires carry the fields below, so they render through
  # their own views. The plan view keeps the canonical sections and layout
  # (pinned by the committed goldens); the two documented
  # deviations keep the wire the single source of truth: the header names the
  # front end instead of the destination (the plan.v1 envelope deliberately
  # does not carry the home path — destination is a status-wire field), and
  # modes print as the wire's canonical octal strings rather than being
  # re-derived. Patches without a text diff print their typed header without
  # a duplicated `link` suffix.
  @doc "Render the hard-cut core status wire (`workstation.status.v1`)."
  def core_status(wire) do
    packages =
      case Enum.map(Map.get(wire, "packages", []), &Map.get(&1, "id")) do
        [] -> "none"
        ids -> Enum.join(ids, ", ")
      end

    journal_line =
      case Map.get(wire, "journal") do
        # A fresh home's journal is null on the wire (canonical-JSON null
        # decodes to the :null atom here) — anything but a map is "none".
        journal when is_map(journal) ->
          "journal: generation=#{journal["generation"]} revision=#{render_value(journal["revision"])}" <>
            maybe_at(journal)

        _ ->
          "journal: none"
      end

    join([
      "workstation status (core)",
      "platform: #{Map.get(wire, "platform", "?")}",
      "packages: #{packages}",
      "graph_order: #{render_value(Map.get(wire, "graph_order", []))}",
      "destination: #{Map.get(wire, "destination", "?")}",
      journal_line,
      update_line(Map.get(wire, "update"))
    ])
  end

  # The availability line (supervisor-directed scope): one human line when
  # the daemon's TTL-cached check RESOLVES — `update: available (local →
  # remote)` when the branch is behind, `update: up to date` otherwise —
  # and ABSENT when the verdict is unknown (offline must look like
  # no-news). `status --json` needs no render-side change: the wire's
  # additive optional `update` object passes through verbatim, and its
  # absence IS the unknown case.
  defp update_line(%{"available" => true, "local" => local, "remote" => remote})
       when is_binary(local) and is_binary(remote) do
    "update: available (#{local} → #{remote})"
  end

  defp update_line(%{"available" => false}), do: "update: up to date"
  defp update_line(_unknown), do: nil

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
  plan preview.
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

  ## capability-domain grouped view (workstation.capabilities.v1)

  alias Workstation.CLI.Capabilities

  # The grouped capability listing (docs/capabilities.md domain order):
  # domain rollups, then per-package rollups, then the file leaves. The
  # planned counts describe the PLAN's would-change set (plan.run patches),
  # never live drift — the wording says so. `files: true` (the --files flag)
  # flattens to the old file-grained listing for scripts that wanted it.
  @domain_pad 12
  @package_pad 12

  @doc "Render the grouped capabilities envelope (`Workstation.CLI.Capabilities.group/1`)."
  @spec capabilities(map(), keyword()) :: String.t()
  def capabilities(envelope, opts \\ []) do
    domains = Map.get(envelope, "domains", [])

    header = [
      "workstation capabilities  generation #{Map.get(envelope, "generation", "?")}  " <>
        "applied #{Map.get(envelope, "applied_generation") || "none"}",
      "#{length(domains)} domains · #{Capabilities.total_files(envelope)} files · " <>
        "#{Capabilities.total_planned(envelope)} would change",
      scope_line(opts)
    ]

    body =
      if(domains == [] and (envelope["unattributed_files"] || 0) == 0,
        do: ["no catalog entries — run `workstation bootstrap`"],
        else: Enum.map(domains, &domain_lines(&1, opts))
      )

    unattributed = Map.get(envelope, "unattributed", [])

    unattributed_lines =
      if unattributed == [] or Keyword.get(opts, :domain),
        do: [],
        else: unattributed_lines(unattributed, opts)

    join(header ++ [nil] ++ List.flatten(body) ++ unattributed_lines)
  end

  defp scope_line(opts) do
    domain = Keyword.get(opts, :domain)
    package = Keyword.get(opts, :package)

    case {domain, package} do
      {nil, nil} -> nil
      {domain, nil} -> "scope: domain #{domain}"
      {nil, package} -> "scope: package #{package}"
      {domain, package} -> "scope: domain #{domain} package #{package}"
    end
  end

  defp domain_lines(domain, opts) do
    packages = Map.get(domain, "packages", [])

    rollup =
      "#{pad(domain["name"], @domain_pad)} targets #{domain["targets"]}   " <>
        "files #{domain["files"]}   planned #{domain["planned"]}"

    package_bodies =
      if Keyword.get(opts, :files) do
        Enum.flat_map(packages, fn package ->
          Enum.map(package["entries"] || [], &file_line(&1, "    "))
        end)
      else
        Enum.flat_map(packages, fn package ->
          package_lines(package, opts)
        end)
      end

    [rollup, package_bodies]
  end

  defp package_lines(package, opts) do
    header =
      "  #{pad(package["name"], @package_pad)} files #{package["files"]}   planned #{package["planned"]}"

    # The default listing keeps the top level rollup-only (the owner's
    # no-raw-file-dump rule); file leaves surface only with explicit
    # drill-down (--package scope, or the deprecated flat --files). The
    # TUI browser drills down interactively.
    files =
      if opts[:package] != nil or opts[:files] == true,
        do: Enum.map(package["entries"] || [], &file_line(&1, "    ")),
        else: []

    [header, files]
  end

  defp unattributed_lines(rows, _opts) do
    header =
      "#{pad("unattributed", @domain_pad)} files #{length(rows)}   planned #{count_planned(rows)}"

    [header, Enum.map(rows, &file_line(&1, "    "))]
  end

  defp count_planned(rows), do: Enum.count(rows, & &1["planned"])

  defp file_line(row, indent) do
    attributes =
      Enum.reject(
        [row["operation"], row["mode"], row["planned"] && "would change", also_note(row)],
        &is_nil/1
      )

    "#{indent}#{String.pad_trailing(row["target"] || "?", 45)} #{Enum.join(attributes, "  ")}"
  end

  defp also_note(%{"also" => also}) when is_list(also) and also != [],
    do: "also: #{Enum.join(also, ",")}"

  defp also_note(_row), do: nil

  defp pad(value, width) when is_binary(value), do: String.pad_trailing(value, width)
  defp pad(value, width), do: String.pad_trailing(to_string(value), width)
end
