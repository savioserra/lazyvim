defmodule Workstation.Daemon.Apply do
  @moduledoc """
  The daemon's engine applier, behind the graduation gate.

  The gate ships OFF: `apply.run` keeps answering the honest `not_graduated`
  refusal until the graduation lane flips the flag
  (`Application.put_env(:daemon, :engine_apply, true)` — the compile-time
  default here is the OFF that ships). A daemon that mutated home state
  through an ungraduated path would fake a graduation, so the wiring exists
  and the refusal is the default, never the other way round. The UPDATE
  lifecycle (`Workstation.Daemon.Update`) re-uses this module as its `apply`
  step executor: `run_current/1` runs the same pipeline without taking the
  lock itself, because the update orchestrator already holds the one lock
  both surfaces serialize through.

  When the gate is open, `run/2` executes the real one-shot pipeline —
  compose the live native catalog (`Catalog.live/1`, no external engine
  process), build the server-side plan (`Catalog` → `Graph` →
  `Source.plan`), then under the apply orchestrator's exclusive lock (the
  SAME lock file the one-shot apply takes): preconditions, publish, backend
  apply, journal record, post-apply verification. The wire request carries
  only the requested generation and display rows — plan bytes are never
  accepted from the client, because a mutation path that trusted client
  bytes would be an unauthenticated write primitive.

  Failures surface as protocol errors with the verbatim engine message under
  the `apply_refused` code: the message is the operator-facing truth (stale
  plan, apply conflict, backend failure), and no code taxonomy can improve on
  quoting it exactly.
  """

  alias Workstation.Core.{ApplyEngine, Catalog, EngineState, Graph, Journal, Source}
  alias Workstation.Daemon.ApplyOrchestrator

  @engine_apply_default false

  @not_graduated_message "the Elixir engine applier is not graduated; this daemon serves no mutation path"

  @doc """
  The one refusal body for every gated mutation surface (`apply.run` with
  the gate closed, and the update lifecycle's mutation steps until the
  graduation lane flips the flag): ONE spelling, because two strings for
  the same gate would let drift fake a distinction between two locks that
  are in fact the same gate.
  """
  @spec not_graduated_message() :: String.t()
  def not_graduated_message, do: @not_graduated_message

  @doc """
  Whether the engine applier is serving mutations. Compile-time default OFF;
  the graduation lane flips it through the application environment at boot.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:daemon, :engine_apply, @engine_apply_default)

  @doc """
  Run one generation apply for `requested_generation` under the exclusive
  apply lock. Returns `{:ok, %{"generation" => generation}}` or a protocol
  error tuple; lock contention maps to the orchestrator's `locked` report.

  Options: `:home` (defaults to the target home) and `:collector` — a
  zero-arity callable returning `{:ok, %Catalog{}}` for SANDBOX catalogs in
  tests; production never passes it and always composes the native live
  catalog.
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, {String.t(), String.t()}}
  def run(requested_generation, opts \\ []) when is_binary(requested_generation) and is_list(opts) do
    home = opts[:home] || EngineState.home()

    with {:ok, plan} <- collect_plan(opts[:collector], home) do
      execute_locked(plan, requested_generation, home)
    end
  end

  # Server-side plan: the live native catalog, then the same read-side
  # composition the CLI evaluates in-process. The
  # plan is built OUTSIDE the lock (the one-shot builds `M.plan`
  # unlocked too) — staleness between collection and lock acquisition is
  # exactly the window the in-lock preconditions exist to catch.
  defp collect_plan(collector, home, code \\ "apply_refused", prefix \\ "apply") do
    collect = collector || fn -> {:ok, Catalog.live(home)} end

    try do
      with {:ok, catalog} <- collect.() do
        graph = Graph.order(%{host: catalog.host, specifications: catalog.packages})

        # The plan records the journal state it was composed against (the Lua
        # changeset baseline): preconditions later compare this stamp against
        # the in-lock journal and refuse a plan the journal advanced past,
        # while the identical desired generation stays an idempotent no-op.
        # Source.plan is pure (a replay probes no filesystem), so the real
        # baseline lands only here, at the composition boundary.
        {:ok,
         Source.with_baseline(
           Source.plan(%{graph: graph}),
           Journal.applied(EngineState.state_root())
         )}
      else
        {:error, reason} ->
          {:error, {code, prefix <> " plan collection failed: #{inspect(reason)}"}}
      end
    rescue
      error in [ArgumentError] ->
        {:error, {code, Exception.message(error)}}
    end
  end

  @doc """
  The update chain's `apply` step: a fresh server-side plan executed under
  the CALLER's orchestrator lock — the update orchestrator already holds
  the apply lock, and a nested `with_lock` would deadlock on the same
  GenServer, so this entry point never acquires; that is the delegation
  contract, not a convenience. No requested generation exists on this
  surface (the chain applies the CURRENT desired state, nothing client
  supplied to be stale), so the built plan's own generation is the truth.
  """
  @spec run_current(keyword()) :: {:ok, map()} | {:error, {String.t(), String.t()}}
  def run_current(opts \\ []) when is_list(opts) do
    home = opts[:home] || EngineState.home()

    with {:ok, plan} <- collect_plan(opts[:collector], home, "update_failed", "update apply") do
      execute_current(plan, home)
    end
  end

  defp execute_current(plan, home) do
    try do
      generation = ApplyEngine.execute(plan, %{"home" => home})
      {:ok, %{"generation" => generation}}
    rescue
      error in ArgumentError ->
        {:error, {"update_failed", Exception.message(error)}}
    end
  end

  defp execute_locked(plan, requested_generation, home) do
    # The lock fun runs in the ORCHESTRATOR process: a raise here would kill
    # that GenServer (socket death for every session) — the same failure mode
    # Update.guarded/1 guards on the update chain. Engine failures therefore
    # fold to an error result INSIDE the fun, so the lock is released and the
    # caller receives an error frame, never a crashed daemon.
    result =
      ApplyOrchestrator.with_lock("apply.run generation=#{requested_generation}", fn ->
        guarded(fn ->
          generation = ApplyEngine.execute(plan, %{"home" => home, "requested_generation" => requested_generation})
          {:ok, %{"generation" => generation}}
        end)
      end)

    case result do
      {:error, {:locked, owner, _path}} -> {:error, {"locked", "apply lock held by #{owner}"}}
      other -> other
    end
  end

  defp guarded(fun) do
    fun.()
  rescue
    error -> {:error, {"apply_refused", Exception.message(error)}}
  catch
    :exit, reason -> {:error, {"apply_refused", "apply aborted: " <> inspect(reason)}}
  end
end
