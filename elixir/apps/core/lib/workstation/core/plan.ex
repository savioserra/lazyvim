defmodule Workstation.Core.Plan do
  @moduledoc """
  The desired-state composition every mutation surface shares: collect the
  catalog, order the graph, render the plan, stamp it with the journal
  baseline. The daemon applier (`Workstation.Daemon.Apply`) and the one-shot
  CLI driver (`Workstation.CLI.Engine`) both call `composed_plan/2`, so the
  collect-fresh -> baseline composition exists exactly once in Core; the
  surfaces differ only in where the apply lock is taken and how errors are
  coded, never in what the plan is composed from.

  Collection happens OUTSIDE the lock on every surface — staleness between
  collection and lock acquisition is exactly the window the engine's in-lock
  preconditions exist to catch — and plan bytes are always composed
  server-side: a mutation path that accepted client bytes would be an
  unauthenticated write primitive.
  """

  alias Workstation.Core.{Catalog, EngineState, Graph, Journal, Source}

  @doc """
  Compose the desired plan for `home`: the live native catalog (or a
  sandbox `collect` — a zero-arity callable returning `{:ok, %Catalog{}}`;
  production never passes one), the ordered graph, and `Source.with_baseline/2`
  against the home's journal. The stamped baseline makes a journal that
  advanced past this plan a precondition refusal, and an identical desired
  generation an idempotent no-op.

  Errors keep their cause explicit so each surface can apply its own wire
  coding: `{:error, {:collect_failed, reason}}` for catalog collection
  failures, `{:error, message}` for the engine preconditions' verbatim
  `ArgumentError` text.
  """
  @spec composed_plan(String.t(), (-> {:ok, Catalog.t()} | {:error, term()}) | nil) ::
          {:ok, Source.t()} | {:error, {:collect_failed, term()}} | {:error, String.t()}
  def composed_plan(home, collect \\ nil) do
    collect = collect || fn -> {:ok, Catalog.live(home)} end

    with {:ok, catalog} <- collect.() do
      graph = Graph.order(%{host: catalog.host, specifications: catalog.packages})

      # The plan records the journal state it was composed against: the
      # engine's preconditions compare this stamp against the in-lock
      # journal. Source.plan is pure (a replay probes no filesystem), so the
      # real baseline lands only here, at the composition boundary.
      {:ok,
       Source.with_baseline(
         Source.plan(%{graph: graph}),
         Journal.applied(state_root(home))
       )}
    else
      {:error, reason} -> {:error, {:collect_failed, reason}}
    end
  rescue
    error in [ArgumentError] -> {:error, Exception.message(error)}
  end

  defp state_root(home), do: Path.join([home | EngineState.state_components()])
end
