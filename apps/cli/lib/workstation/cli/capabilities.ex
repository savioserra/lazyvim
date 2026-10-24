defmodule Workstation.CLI.Capabilities do
  @moduledoc """
  The capability-domain grouping of the declared state — ONE source of truth
  consumed by the `workstation capabilities` verb (text and `--json`) and by
  the TUI capabilities browser, so the CLI listing and the browser can never
  disagree about structure or counts.

  The module is a PURE VIEW over two existing read wires (no engine changes,
  no new daemon op):

    * `workstation.status.v2` — supplies the per-capability accounting rows
      (id, foundation, fileTargets, claimTargets, fragments, retire) and the
      capability order, report-verbatim;
    * `workstation.plan.v2` — supplies the probed live state per declared
      target (`target_states`), the declared-vs-live review surface.

  Grain contract (the owner's directive): domains (L1) and capabilities (L2)
  are the rollup levels, declared targets (L3) the drill-down leaves — never
  a raw file dump at the top. Counts are recomputed from the target rows on
  every fold (derived, never cached), so rollups cannot drift from the
  leaves.

  Attribution rule — every declared target is visible EXACTLY once: the
  report's accounting rows attribute each target to exactly one capability
  (the fold's integrity assertions enforce the composition nix-side), and
  the rows keep that attribution. A row without a foundation still renders
  (appended, sorted) rather than vanishing — a wrong-grained taxonomy is
  surfaced, not hidden.

  Domain order is the lifecycle order pinned by docs/capabilities.md; a
  foundation name outside the pinned set still renders (appended, sorted)
  rather than vanishing.

  Planned counts are always zero: the read verbs declare, the nix switch
  drivers mutate — nothing queues on the wire.
  """

  @schema "workstation.capabilities.v1"

  # docs/capabilities.md lifecycle order (foundation/<name> suffixes).
  @domain_order ~w(base fonts runtime editor terminal theme agent secrets)

  @typedoc "Scope options: `:domain` and `:capability` narrow the envelope."
  @type scope_opt :: {:domain, String.t() | nil} | {:capability, String.t() | nil}

  @doc "Schema identifier of the grouped envelope."
  @spec schema() :: String.t()
  def schema, do: @schema

  @doc """
  Fold one status wire + one plan wire into the grouped envelope:

      %{
        "schema" => #{@schema},
        "generation" => plan generation (the report digest),
        "domains" => [
          %{"name" => "editor", "foundation" => "foundation/editor",
            "targets" => 1, "files" => 6, "planned" => 0,
            "capabilities" => [
              %{"name" => "editor", "files" => 6, "planned" => 0,
                "entries" => [target_row()]}
            ]}
        ],
        "unattributed" => [target_row()],
        "unattributed_files" => 0,
        "unattributed_planned" => 0
      }

  Target rows: `%{"name" => target, "target" => path, "operation" =>
  "file" | "tree" | "retire", "mode" => nil, "planned" => false,
  "also" => []}`.
  """
  @spec group(%{required(String.t()) => map()}) :: map()
  def group(%{"status" => status, "plan" => plan}) when is_map(status) and is_map(plan) do
    rows = wire_list(status["capabilities"])

    domains =
      rows
      |> Enum.group_by(& &1["foundation"])
      |> Enum.map(fn {foundation, capability_rows} ->
        capability_rows = Enum.sort_by(capability_rows, & &1["id"])

        capabilities =
          Enum.map(capability_rows, fn row ->
            entries = capability_entries(row)
            files = length(entries)

            %{
              "name" => row["id"],
              "files" => files,
              "planned" => 0,
              "entries" => entries
            }
          end)

        %{
          "name" => foundation_name(foundation),
          "foundation" =>
            (is_binary(foundation) && "foundation/#{foundation}") ||
              "foundation/unattributed-taxonomy",
          "targets" => length(capabilities),
          "files" => Enum.reduce(capabilities, 0, &(&1["files"] + &2)),
          "planned" => 0,
          "capabilities" => capabilities
        }
      end)
      |> Enum.sort_by(&domain_sort_key(&1["name"]))

    %{
      "schema" => @schema,
      "generation" => plan["generation"],
      "domains" => domains,
      "unattributed" => [],
      "unattributed_files" => 0,
      "unattributed_planned" => 0
    }
  end

  def group(_wires), do: raise_arg("group/1 needs %{\"status\" => wire, \"plan\" => wire}")

  @doc """
  Scope one grouped envelope: `domain: "editor"` keeps that domain block,
  `capability: "editor"` keeps the capability inside its domain block.
  Unknown scopes keep an empty envelope (the render says so) — never an
  error, matching the read verbs' informational contract.
  """
  @spec scope(map(), [scope_opt()]) :: map()
  def scope(envelope, opts) do
    domain = opt(opts, :domain)
    capability = opt(opts, :capability)

    domains =
      envelope["domains"]
      |> wire_list()
      |> Enum.filter(fn d -> domain == nil or d["name"] == domain end)
      |> Enum.map(fn d ->
        if capability == nil do
          d
        else
          capabilities = Enum.filter(d["capabilities"], &(&1["name"] == capability))

          if capabilities == [] do
            # A capability lives in exactly one domain: domains without it
            # are dropped, not zeroed (the scope implies its domain).
            nil
          else
            replan(d, capabilities)
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

  @doc "Total declared-target rows of one envelope (the header count)."
  @spec total_files(map()) :: non_neg_integer()
  def total_files(envelope) do
    domains =
      wire_list(envelope["domains"])
      |> Enum.reduce(0, fn domain, acc ->
        acc +
          (wire_list(domain["capabilities"])
           |> Enum.reduce(0, fn c, n -> n + (c["files"] || 0) end))
      end)

    domains + (envelope["unattributed_files"] || 0)
  end

  @doc "Total planned-change rows of one envelope (the header count) — always zero."
  @spec total_planned(map()) :: non_neg_integer()
  def total_planned(envelope) do
    planned =
      wire_list(envelope["domains"])
      |> Enum.reduce(0, fn domain, acc ->
        acc +
          (wire_list(domain["capabilities"])
           |> Enum.reduce(0, fn c, n -> n + (c["planned"] || 0) end))
      end)

    planned + (envelope["unattributed_planned"] || 0)
  end

  ## row folding

  # One capability row → its declared target rows: file targets, tree
  # claims, then the retire tombstones (the report's declared order inside
  # each surface). The live state rides the plan wire's target_states.
  defp capability_entries(row) do
    Enum.concat([
      Enum.map(row["fileTargets"] || [], &entry(&1, "file")),
      Enum.map(row["claimTargets"] || [], &entry(&1, "tree")),
      Enum.map(row["retire"] || [], &entry(&1, "retire"))
    ])
    |> Enum.sort_by(& &1["target"])
  end

  defp entry(target, operation) do
    %{
      "name" => target,
      "target" => target,
      "operation" => operation,
      "mode" => nil,
      "planned" => false,
      "also" => []
    }
  end

  defp foundation_name("foundation/" <> name), do: name
  defp foundation_name(name) when is_binary(name), do: name
  defp foundation_name(nil), do: "unattributed"

  defp domain_sort_key(name) do
    index = Enum.find_index(@domain_order, &(&1 == name))
    {index || length(@domain_order), name}
  end

  defp replan(domain, capabilities) do
    %{
      domain
      | "capabilities" => capabilities,
        "targets" => length(capabilities),
        "files" => Enum.reduce(capabilities, 0, &(&1["files"] + &2)),
        "planned" => Enum.reduce(capabilities, 0, &(&1["planned"] + &2))
    }
  end

  defp wire_list(value) when is_list(value), do: value
  defp wire_list(nil), do: []
  defp wire_list(_other), do: []

  defp opt(opts, key), do: (Keyword.get(opts, key) in [nil, ""] && nil) || Keyword.get(opts, key)

  defp raise_arg(message), do: raise(ArgumentError, message)
end
