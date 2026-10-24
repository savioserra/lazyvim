defmodule Workstation.CLI.Render do
  @moduledoc """
  Plain-text rendering of the hard-cut core wire schemas
  (`workstation.status.v2`, `workstation.plan.v2`).

  Non-TTY output is always plain text; this module is deliberately
  terminal-free so output is stable under redirection and in tests. The
  wires are assembled once, daemon-side (`Workstation.Daemon.Read`) over
  the baked declared-state report; field order is fixed, so identical
  declared state renders identical text.
  """

  ## core wire views (workstation.{status,plan}.v2)

  @doc "Render the hard-cut core status wire (`workstation.status.v2`)."
  def core_status(wire) do
    counts = Map.get(wire, "counts", %{})
    capabilities = Map.get(wire, "capabilityOrder", [])

    capability_list =
      case capabilities do
        [] -> "none"
        ids -> Enum.join(ids, ", ")
      end

    join([
      "workstation status (core)",
      "  engine     : #{wire["engine"]["name"]} #{wire["engine"]["version"]} " <>
        "(mode: #{wire["engine"]["mode"]})",
      "  destination: #{Map.get(wire, "destination", "?")}",
      "  platform   : #{Map.get(wire, "platform", "?")}",
      "  declared   : #{counts["fileTargets"] || 0} file targets · " <>
        "#{counts["claimTargets"] || 0} tree claims · #{counts["fragments"] || 0} fragments · " <>
        "#{counts["retire"] || 0} retire",
      "  capabilities (#{length(capabilities)}): #{capability_list}"
    ])
  end

  @doc """
  Render the hard-cut core plan wire (`workstation.plan.v2`) as the human
  plan preview: the declared surface plus the probed per-target live states.
  """
  def core_plan(wire) do
    declared = Map.get(wire, "declared", %{})
    states = Map.get(wire, "target_states", %{})

    file_targets = Map.get(declared, "fileTargets", [])
    claim_targets = Map.get(declared, "claimTargets", [])
    retire = Map.get(declared, "retire", [])
    fragments = Map.get(declared, "fragmentOrder", [])
    fragment_count = fragments |> Enum.map(&length(&1["fragments"] || [])) |> Enum.sum()

    fragment_line =
      case fragments do
        [] -> "  fragments  : none"
        _ -> "  fragments  : #{fragment_count} on #{length(fragments)} rc targets"
      end

    retire_line =
      case retire do
        [] -> []
        tombstones -> ["  retire     : #{length(tombstones)} (#{Enum.join(tombstones, ", ")})"]
      end

    target_lines =
      (file_targets ++ claim_targets)
      |> Enum.map(&target_line(&1, states, ""))
      |> Enum.concat(Enum.map(retire, &target_line(&1, states, " (retire)")))

    join([
      "workstation plan (core)",
      "  generation : #{Map.get(wire, "generation", "?")}",
      "  declared   : #{length(file_targets)} file targets · #{length(claim_targets)} tree claims",
      fragment_line,
      retire_line,
      target_lines,
      "plan complete."
    ])
  end

  defp target_line(target, states, suffix) do
    "  target #{String.pad_trailing(target, 45)} #{Map.get(states, target, "?")}#{suffix}"
  end

  defp join(lines) do
    lines
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  ## capability-domain grouped view (workstation.capabilities.v1)

  alias Workstation.CLI.Capabilities

  # The grouped capability listing (docs/capabilities.md domain order):
  # domain rollups, then per-capability rollups, then the declared target
  # leaves. The planned counts are always zero — nothing queues: the read
  # verbs declare, the nix switch drivers mutate. `files: true` (the --files
  # flag) flattens to the file-grained listing for scripts that want it.
  @domain_pad 12
  @capability_pad 12

  @doc "Render the grouped capabilities envelope (`Workstation.CLI.Capabilities.group/1`)."
  @spec capabilities(map(), keyword()) :: String.t()
  def capabilities(envelope, opts \\ []) do
    domains = Map.get(envelope, "domains", [])

    header = [
      "workstation capabilities  generation #{Map.get(envelope, "generation", "?")}",
      "#{length(domains)} domains · #{Capabilities.total_files(envelope)} files · " <>
        "#{Capabilities.total_planned(envelope)} would change",
      scope_line(opts)
    ]

    body =
      if(domains == [] and (envelope["unattributed_files"] || 0) == 0,
        do: ["no declared targets — the report carries no declared surface"],
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
    capability = Keyword.get(opts, :capability)

    case {domain, capability} do
      {nil, nil} -> nil
      {domain, nil} -> "scope: domain #{domain}"
      {nil, capability} -> "scope: capability #{capability}"
      {domain, capability} -> "scope: domain #{domain} capability #{capability}"
    end
  end

  defp domain_lines(domain, opts) do
    capabilities = Map.get(domain, "capabilities", [])

    rollup =
      "#{pad(domain["name"], @domain_pad)} targets #{domain["targets"]}   " <>
        "files #{domain["files"]}   planned #{domain["planned"]}"

    capability_bodies =
      if Keyword.get(opts, :files) do
        Enum.flat_map(capabilities, fn capability ->
          Enum.map(capability["entries"] || [], &file_line(&1, "    "))
        end)
      else
        Enum.flat_map(capabilities, fn capability ->
          capability_lines(capability, opts)
        end)
      end

    [rollup, capability_bodies]
  end

  defp capability_lines(capability, opts) do
    header =
      "  #{pad(capability["name"], @capability_pad)} files #{capability["files"]}   planned #{capability["planned"]}"

    # The default listing keeps the top level rollup-only (the owner's
    # no-raw-file-dump rule); declared targets surface only with explicit
    # drill-down (--capability scope, or the flat --files). The TUI browser
    # drills down interactively.
    files =
      if opts[:capability] != nil or opts[:files] == true,
        do: Enum.map(capability["entries"] || [], &file_line(&1, "    ")),
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
