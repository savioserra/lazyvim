defmodule Workstation.CLI.Capabilities do
  @moduledoc """
  The capability-domain grouping of the desired state — ONE source of truth
  consumed by the `workstation capabilities` verb (text and `--json`) and by
  the TUI capabilities browser, so the CLI listing and the browser can never
  disagree about structure or counts.

  The module is a PURE VIEW over two existing read wires (no engine changes,
  no new daemon op):

    * `workstation.status.v1` — supplies `taxonomy` (package id → declared
      `foundation/<domain>` layer, `Workstation.Core.Catalog.Packages`)
      and `journal` (the last applied generation, for the header).
    * `workstation.plan.v1` — supplies the full file inventory: `plan`
      entries are every planned target with their `attribution` (the owning
      package ids), and `patches` are the subset that WOULD CHANGE against
      the current state (kind add/change) plus retired-target deletions.

  Grain contract (the owner's directive): domains (L1) and packages (L2)
  are the rollup levels, files (L3) the drill-down leaves — never a raw
  file dump at the top. Counts are recomputed from the file rows on every
  fold (derived, never cached), so rollups cannot drift from the leaves.

  Attribution rule — every file is visible EXACTLY once: a plan entry's
  `attribution` lists every package contributing to the target; the entry
  files under its PRIMARY package (`hd(attribution)`), and the remaining
  contributors ride the row as `"also"` (rendered as a note, never extra
  rows). Entries with an empty or absent attribution land in the honest
  `unattributed` bucket instead of being dropped. A patch record for a
  target with no plan entry is a retired-target deletion and appears as an
  `operation: "delete"` row under its own attribution.

  Domain order is the lifecycle order pinned by docs/capabilities.md and
  `Workstation.Core.Catalog.Packages.@known_foundations`; a foundation name
  outside the pinned set still renders (appended, sorted) rather than
  vanishing — a wrong-grained taxonomy is surfaced, not hidden.
  """

  @schema "workstation.capabilities.v1"

  # docs/capabilities.md lifecycle order (foundation/<name> suffixes).
  @domain_order ~w(base fonts runtime editor terminal theme agent secrets)

  @typedoc "Scope options: `:domain` and `:package` narrow the envelope."
  @type scope_opt :: {:domain, String.t() | nil} | {:package, String.t() | nil}

  @doc "Schema identifier of the grouped envelope."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc """
  Fold one status wire + one plan wire into the grouped envelope:

      %{
        "schema" => #{@schema},
        "generation" => plan generation,
        "applied_generation" => journal generation | nil,
        "domains" => [
          %{"name" => "editor", "foundation" => "foundation/editor",
            "targets" => 1, "files" => 21, "planned" => 2,
            "packages" => [
              %{"name" => "nvim", "files" => 21, "planned" => 2,
                "entries" => [entry_row()]}
            ]}
        ],
        "unattributed" => [entry_row()],
        "unattributed_files" => 3,
        "unattributed_planned" => 1
      }

  Entry rows: `%{"name" => source, "target" => path, "operation" => op,
  "mode" => octal | nil, "planned" => boolean, "also" => [package]}`.
  """
  @spec group(%{required(String.t()) => map()}) :: map()
  def group(%{"status" => status, "plan" => plan}) when is_map(status) and is_map(plan) do
    # The status wire's taxonomy is a package -> foundation MAP (unlike the
    # wire's list-shaped sections) — never pass it through wire_list.
    taxonomy = (is_map(status["taxonomy"]) && status["taxonomy"]) || %{}
    entries = wire_list(get_in(plan, ["plan", "entries"]))
    patches = wire_list(plan["patches"])

    planned_targets = MapSet.new(patches, & &1["target"])
    deletions = Enum.filter(patches, &(&1["kind"] == "delete"))

    grouped =
      entries
      |> Enum.map(&entry_row(&1, planned_targets))
      |> Kernel.++(Enum.map(deletions, &deletion_row(&1)))
      |> Enum.group_by(&primary_package/1)

    # Map.pop/3 yields {popped_value, rest_map}: the unattributed list
    # pops out, the rest map stays attributed.
    {unattributed, attributed} = Map.pop(grouped, :unattributed, [])

    domains =
      attributed
      |> Enum.map(fn {package, rows} -> {package, package_rows(rows)} end)
      |> Enum.map(fn {package, {rows, planned}} ->
        {Map.get(taxonomy, package), package, rows, planned}
      end)
      |> Enum.group_by(fn {foundation, _package, _rows, _planned} -> foundation end)
      |> Enum.map(fn {foundation, packages} ->
        packages = Enum.sort_by(packages, fn {_f, package, _rows, _planned} -> package end)

        %{
          "name" => foundation_name(foundation),
          "foundation" => foundation || "foundation/unattributed-taxonomy",
          "targets" => length(packages),
          "files" =>
            Enum.reduce(packages, 0, fn {_f, _p, rows, _planned}, acc -> length(rows) + acc end),
          "planned" =>
            Enum.reduce(packages, 0, fn {_f, _p, _rows, planned}, acc -> planned + acc end),
          "packages" =>
            Enum.map(packages, fn {_f, package, rows, planned} ->
              %{
                "name" => package,
                "files" => length(rows),
                "planned" => planned,
                "entries" => Enum.sort_by(rows, & &1["target"])
              }
            end)
        }
      end)
      |> Enum.sort_by(&domain_sort_key(&1["name"]))

    %{
      "schema" => @schema,
      "generation" => plan["generation"],
      "applied_generation" => journal_generation(status["journal"]),
      "domains" => domains,
      "unattributed" => Enum.sort_by(unattributed || [], & &1["target"]),
      "unattributed_files" => length(unattributed || []),
      "unattributed_planned" => count_planned(unattributed || [])
    }
  end

  def group(_wires), do: raise_arg("group/1 needs %{\"status\" => wire, \"plan\" => wire}")

  @doc """
  Scope one grouped envelope: `domain: "editor"` keeps that domain block,
  `package: "nvim"` keeps the package inside its domain block. Unknown
  scopes keep an empty envelope (the render says so) — never an error,
  matching the read verbs' informational contract.
  """
  @spec scope(map(), [scope_opt()]) :: map()
  def scope(envelope, opts) do
    domain = opt(opts, :domain)
    package = opt(opts, :package)

    domains =
      envelope["domains"]
      |> wire_list()
      |> Enum.filter(fn d -> domain == nil or d["name"] == domain end)
      |> Enum.map(fn d ->
        if package == nil do
          d
        else
          packages = Enum.filter(d["packages"], &(&1["name"] == package))

          if packages == [] do
            # A package lives in exactly one domain: domains without it are
            # dropped, not zeroed (the scope implies its domain).
            nil
          else
            replan(d, packages)
          end
        end
      end)
      |> Enum.reject(&is_nil/1)

    keep_unattributed = domain == nil

    %{
      envelope
      | "domains" => domains,
        "unattributed" => if(keep_unattributed, do: envelope["unattributed"], else: []),
        "unattributed_files" =>
          if(keep_unattributed, do: envelope["unattributed_files"], else: 0),
        "unattributed_planned" =>
          if(keep_unattributed, do: envelope["unattributed_planned"], else: 0)
    }
  end

  @doc "Total file rows of one envelope (the header count)."
  @spec total_files(map()) :: non_neg_integer()
  def total_files(envelope) do
    domains =
      wire_list(envelope["domains"])
      |> Enum.reduce(0, fn domain, acc ->
        acc +
          (wire_list(domain["packages"]) |> Enum.reduce(0, fn p, n -> n + (p["files"] || 0) end))
      end)

    domains + (envelope["unattributed_files"] || 0)
  end

  @doc "Total planned-change rows of one envelope (the header count)."
  @spec total_planned(map()) :: non_neg_integer()
  def total_planned(envelope) do
    planned =
      wire_list(envelope["domains"])
      |> Enum.reduce(0, fn domain, acc ->
        acc +
          (wire_list(domain["packages"])
           |> Enum.reduce(0, fn p, n -> n + (p["planned"] || 0) end))
      end)

    planned + (envelope["unattributed_planned"] || 0)
  end

  ## row folding

  # One plan entry (or deletion patch) → one file row. Planned = the target
  # carries a would-change patch (add/change) or the row IS a deletion.
  # Entries key their source as "source_name" (the changeset view's
  # post-decode shape); patches key it "source".
  defp entry_row(entry, planned_targets) do
    {primary, also} = split_attribution(entry["attribution"])

    %{
      "name" => entry["source_name"],
      "target" => entry["target"],
      "operation" => entry["operation"],
      "mode" => entry["mode"],
      "planned" => MapSet.member?(planned_targets, entry["target"]),
      "primary" => primary || :unattributed,
      "also" => also
    }
  end

  defp deletion_row(patch) do
    {primary, also} = split_attribution(patch["attribution"])

    %{
      "name" => patch["source"],
      "target" => patch["target"],
      "operation" => "delete",
      "mode" => patch["mode"],
      "planned" => true,
      "primary" => primary || :unattributed,
      "also" => also
    }
  end

  defp split_attribution(value) do
    case wire_list(value) do
      [] -> {nil, []}
      [primary | also] -> {primary, also}
    end
  end

  defp primary_package(%{"primary" => :unattributed}), do: :unattributed
  defp primary_package(%{"primary" => package}) when is_binary(package), do: package
  # A row without any attribution key at all is unattributed by definition.
  defp primary_package(_row), do: :unattributed

  defp package_rows(rows) do
    rows = Enum.map(rows, &Map.delete(&1, "primary"))
    {rows, count_planned(rows)}
  end

  defp count_planned(rows), do: Enum.count(rows, & &1["planned"])

  defp journal_generation(%{"generation" => generation}) when is_binary(generation),
    do: generation

  defp journal_generation(_none), do: nil

  defp foundation_name("foundation/" <> name), do: name
  defp foundation_name(name) when is_binary(name), do: name
  defp foundation_name(nil), do: "unattributed"

  defp domain_sort_key(name) do
    index = Enum.find_index(@domain_order, &(&1 == name))
    {index || length(@domain_order), name}
  end

  defp replan(domain, packages) do
    %{
      domain
      | "packages" => packages,
        "targets" => length(packages),
        "files" => Enum.reduce(packages, 0, &(&1["files"] + &2)),
        "planned" => Enum.reduce(packages, 0, &(&1["planned"] + &2))
    }
  end

  defp wire_list(value) when is_list(value), do: value
  defp wire_list(nil), do: []
  defp wire_list(_other), do: []

  defp opt(opts, key), do: (Keyword.get(opts, key) in [nil, ""] && nil) || Keyword.get(opts, key)

  defp raise_arg(message), do: raise(ArgumentError, message)
end
