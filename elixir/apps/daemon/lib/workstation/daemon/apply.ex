defmodule Workstation.Daemon.Apply do
  @moduledoc """
  The daemon's engine applier — the one mutation path since the client/
  server refactor.

  The graduation gate is RETIRED OPEN: the daemon is the engine's only
  mutation surface, so `apply.run` serves the real pipeline by default
  (`@engine_apply_default true`). The application environment key remains
  settable (`Application.put_env(:daemon, :engine_apply, false)`) purely so
  the refusal path stays exercisable in tests — a closed gate answers the
  honest `not_graduated` refusal on every gated mutation surface. The update
  lifecycle (`Workstation.Daemon.Lifecycle`) executes its `apply` step
  itself — a fresh server-side plan run inline through `ApplyEngine.execute`
  inside the step's own lock acquisition — so this module stays the
  `apply.run` op surface.

  When the gate is open, `run/2` executes the real one-shot pipeline —
  compose the desired plan through the shared Core composition
  (`Workstation.Core.Plan.composed_plan/2`: live native catalog, no
  external engine process), then under the apply orchestrator's exclusive lock (the
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

  alias Workstation.Core.{ApplyEngine, EngineState, Plan}
  alias Workstation.Daemon.{ApplyOrchestrator, Events}

  @engine_apply_default true

  @not_graduated_message "the Elixir engine applier is not graduated; this daemon serves no mutation path"

  @doc """
  The one refusal body for every gated mutation surface (an `apply.run` or
  update-lifecycle mutation step with the gate explicitly closed in the
  application environment): ONE spelling, because two strings for
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
    op_ref = opts[:op_ref]

    if op_ref,
      do:
        Events.emit(op_ref, "run.started", %{"op" => "apply.run", "generation" => requested_generation})

    result =
      with {:ok, plan} <- collect_plan(opts[:collector], home) do
        execute_locked(plan, requested_generation, home)
      end

    case result do
      {:ok, _record} ->
        if op_ref, do: Events.emit(op_ref, "run.finished", %{"outcome" => "ok"})

      {:error, {code, message}} ->
        if op_ref,
          do: Events.emit(op_ref, "run.finished", %{"outcome" => "failed", "error" => "#{code}: #{message}"})
    end

    result
  end

  # Server-side plan: the shared Core composition (`Workstation.Core.Plan`),
  # the same read-side composition the one-shot CLI evaluates in-process. The
  # plan is built OUTSIDE the lock (the one-shot composes unlocked too) —
  # staleness between collection and lock acquisition is exactly the window
  # the in-lock preconditions exist to catch. Errors are coded for this
  # surface (`apply_refused`).
  defp collect_plan(collector, home) do
    case Plan.composed_plan(home, collector) do
      {:ok, plan} ->
        {:ok, plan}

      {:error, {:collect_failed, reason}} ->
        {:error, {"apply_refused", "apply plan collection failed: #{inspect(reason)}"}}

      {:error, message} ->
        {:error, {"apply_refused", message}}
    end
  end

  defp execute_locked(plan, requested_generation, home) do
    # The lock fun runs in the ORCHESTRATOR process: a raise here would kill
    # that GenServer (socket death for every session) — the same failure mode
    # Workstation.Daemon.Lifecycle.guarded/3 guards on the update chain.
    # Engine failures therefore fold to an error result INSIDE the fun, so the
    # lock is released and the caller receives an error frame, never a crashed
    # daemon.
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
