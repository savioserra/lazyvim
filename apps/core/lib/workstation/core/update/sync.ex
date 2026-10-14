defmodule Workstation.Core.Update.Sync do
  @moduledoc """
  The `sync` step of the update lifecycle: re-collect the live home and
  reconcile the freshly built plan against the journal's applied generation.

  Reconciliation is the read-only twin the update chain needs AFTER apply:
  compose the live native catalog again, rebuild the server-side plan (the
  same `Catalog` → `Graph` → `Source.plan` composition the applier runs),
  and compare generations. A fresh plan that no longer matches the applied
  generation means the source state moved on between apply and sync — mid
  an update that is a real abort, because the chain's "applied" claim is
  already stale. The step mutates nothing: engine state changes only inside
  the apply orchestration.
  """

  alias Workstation.Core.{Catalog, EngineState, Graph, Journal, Source}

  @doc """
  Reconcile. Returns
  `{:ok, %{"step" => "sync", "status" => "ok", "generation" => generation,
  "revision" => revision}}`; raises `ArgumentError` when nothing was ever
  applied, the collector or plan pipeline fails, or the fresh plan
  generation diverges from the journal.

  Options: `:home` (defaults to the target home) and `:collector` — a
  zero-arity callable returning `{:ok, %Catalog{}}` for SANDBOX catalogs in
  tests; production never passes it and always composes the native live
  catalog (`Catalog.live/1`).
  """
  @spec run(keyword()) :: {:ok, map()}
  def run(opts \\ []) when is_list(opts) do
    home = Keyword.get(opts, :home) || EngineState.home()
    state_root = Path.join([home | EngineState.state_components()])

    applied = Journal.applied(state_root)

    unless applied,
      do: raise(ArgumentError, "sync: no applied generation to reconcile; run apply first")

    generation = fresh_generation!(home, opts)

    unless generation == applied["generation"],
      do:
        raise(
          ArgumentError,
          "sync: reconciliation failed: the live source plans generation #{inspect(generation)} " <>
            "but the journal holds applied generation #{inspect(applied["generation"])}; re-run apply"
        )

    {:ok, %{"step" => "sync", "status" => "ok", "generation" => generation, "revision" => applied["revision"]}}
  end

  # The plan composition is deliberately the applier's (one spelling of the
  # read-side pipeline); the failure prefix names THIS surface so a wire
  # message says which lifecycle step refused.
  defp fresh_generation!(home, opts) do
    collect = Keyword.get(opts, :collector) || fn -> {:ok, Catalog.live(home)} end

    with {:ok, catalog} <- collect.(),
         graph <- Graph.order(%{host: catalog.host, specifications: catalog.packages}),
         %Source{generation: generation} <- Source.plan(%{graph: graph}) do
      generation
    else
      {:error, reason} ->
        raise ArgumentError, "sync: plan collection failed: #{inspect(reason)}"
    end
  rescue
    error in [ArgumentError] ->
      reraise ArgumentError, "sync: plan collection failed: #{Exception.message(error)}", __STACKTRACE__
  end
end
