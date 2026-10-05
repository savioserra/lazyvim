defmodule Workstation.CLI.Output do
  @moduledoc """
  Hard-cut CLI output wire schemas (lane b5): exactly one schema per
  command, versioned, never reshaped by a caller. Native collection
  (`Workstation.Core.Catalog.live/1`) replaced the retired Lua collector
  bridge; what the CLI emits on stdout is one of the schemas below.

    * `workstation.status.v1` — {schema, engine{name, version, mode
      "lua"|"elixir"}, destination, platform, packages[{id, requires,
      supported_hosts}], graph_order, journal{generation, revision, at}|null,
      taxonomy: %{package_id => declared foundation layer} (live-catalog metadata,
      absent from envelopes/plan bytes by design)}
    * `workstation.plan.v1` — nested envelope: {schema, generation, plan,
      manifest, patches, target_states}. The `plan` body is the
      parity-locked golden plan view (byte-identical to
      tests/goldens/<profile>/expected/plan.json, nothing added inside it)
      and `manifest` is the recorded manifest verbatim — content-addressed
      artifacts must not be smuggled into the parity body. `patches` and
      `target_states` are genuinely new b5 outputs and live at envelope
      level for the same reason.
    * `workstation.diff.v1` — {schema, generation, backend_diff verbatim}.

  Builders are total and pure: they only place already-validated values,
  so identical engine/core state yields identical wire maps and therefore
  identical canonical JSON bytes (Workstation.Core.CanonicalJSON sorts
  object keys; every map here is far below the Erlang small-map bound).
  """

  @status_schema "workstation.status.v1"
  @plan_schema "workstation.plan.v1"
  @diff_schema "workstation.diff.v1"

  @doc "Schema identifier of the hard-cut status wire."
  def status_schema, do: @status_schema

  @doc "Schema identifier of the hard-cut plan wire."
  def plan_schema, do: @plan_schema

  @doc "Schema identifier of the hard-cut diff wire."
  def diff_schema, do: @diff_schema

  @doc """
  Build the status wire. `packages` are the collected envelope packages
  (id/requires/supported_hosts verbatim), `graph_order` the resolved
  package ids, `journal` the applied record or nil when nothing was ever
  applied, `taxonomy` the live catalog's package -> foundation declaration
  (descriptive metadata only; it never enters envelopes or plan bytes).
  """
  @spec status(String.t(), String.t(), String.t(), String.t(), [map()], [String.t()], map() | nil, %{
          String.t() => String.t()
        }) :: map()
  def status(engine_name, mode, destination, platform, packages, graph_order, journal, taxonomy) do
    %{
      "schema" => @status_schema,
      "engine" => %{"name" => engine_name, "version" => cli_version(), "mode" => mode},
      "destination" => destination,
      "platform" => platform,
      "packages" => packages,
      "graph_order" => graph_order,
      "taxonomy" => taxonomy,
      # Explicit null token: the canonical encoder drops literal nils, but
      # the status schema keeps journal present as JSON null when nothing
      # was ever applied.
      "journal" => (journal && journal_wire(journal)) || :null
    }
  end

  @doc """
  Build the plan wire. `plan_body` must already be the golden-verbatim
  projected view, `manifest` the plan manifest verbatim; `patches` and
  `target_states` are the b5 additions (changeset patches and the probed
  target states of every planned target).
  """
  @spec plan(String.t(), map(), [map()], [map()], map()) :: map()
  def plan(generation, plan_body, manifest, patches, target_states) do
    %{
      "schema" => @plan_schema,
      "generation" => generation,
      "plan" => plan_body,
      "manifest" => manifest,
      "patches" => patches,
      "target_states" => target_states
    }
  end

  @doc """
  Build the diff wire: `backend_diff` is the structured change-set record
  list verbatim (the same records the retired Lua reporter's diff payload
  carried and the parity goldens still pin).
  `generation` is the desired generation the records were computed against.
  """
  @spec diff(String.t(), [map()]) :: map()
  def diff(generation, backend_diff) do
    %{
      "schema" => @diff_schema,
      "generation" => generation,
      "backend_diff" => backend_diff
    }
  end

  defp journal_wire(journal) do
    %{"generation" => journal["generation"], "revision" => journal["revision"]}
    |> maybe_put("at", journal["at"])
  end

  # Canonical JSON drops nil map values (a Lua nil field does not exist), so
  # optional wire fields are omitted rather than emitted as nulls.
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp cli_version, do: to_string(Application.spec(:cli, :vsn) || "0.0.0")
end
