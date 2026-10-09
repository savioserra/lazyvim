defmodule Workstation.Daemon.ApplyOrchestrator do
  @moduledoc """
  Single orchestrated generation: the daemon-side serialization and lock
  primitive around apply-shaped work.

  Lock semantics:

  * the lock file is `<state_root>/apply.lock` — the SAME file the one-shot
    apply takes, so a daemon orchestration and a one-shot apply can
    never run concurrently against one target; mutual exclusion is a
    filesystem fact, not a convention between two Elixir processes;
  * the lock is created exclusively (`wx`, mode 0600); when it already
    exists the recorded owner metadata is reported and the acquisition FAILS
    CLOSED — stale locks are never stolen, recovery is always the operator
    inspecting the recorded owner and removing the file deliberately;
  * an unreadable or malformed lock body is reported as
    "unreadable or malformed lock" instead of being treated as absent, so a
    corrupted lock cannot silently re-enable concurrency;
  * a holder releases only its OWN invocation: the release re-reads the file
    and removes it only when the recorded token still matches — a holder
    never deletes a lock another operation replaced in between.

  The orchestrator itself serializes in-daemon requests through its
  GenServer mailbox (one orchestrated generation at a time for the whole
  daemon) before any lock is taken, so sessions queue here instead of racing
  on the filesystem. The lock file semantics themselves live in
  `Workstation.Core.ApplyLock` (shared verbatim with the one-shot CLI
  driver); the flag-gated engine applier
  (`Workstation.Daemon.Apply`) runs its real pipeline inside `with_lock/2`;
  the refusal path keeps exercising the same lock while the graduation gate
  is closed.
  """

  use GenServer

  alias Workstation.Core.ApplyLock

  @lock_name "apply.lock"
  @doc """
  Run `fun` while holding the target's apply lock. Returns `fun`'s result or
  `{:error, {:locked, owner, lock_path}}` when another operation holds the
  lock — the daemon never waits the lock out and never steals it.
  """
  @spec with_lock(String.t(), (-> result)) :: result | {:error, {:locked, String.t(), String.t()}} when result: var
  def with_lock(purpose, fun) do
    GenServer.call(__MODULE__, {:with_lock, purpose, fun}, :infinity)
  end

  @doc "Acquire without running anything; returns the release token or the lock holder report."
  @spec acquire(String.t()) :: {:ok, reference(), String.t()} | {:error, {:locked, String.t(), String.t()}}
  def acquire(purpose), do: GenServer.call(__MODULE__, {:acquire, purpose})

  @doc "Release only if `token` still identifies the current lock file."
  @spec release(reference()) :: :ok | {:error, :not_owner}
  def release(token), do: GenServer.call(__MODULE__, {:release, token})

  @doc "The lock file path for one state root (exposed for tests and diagnostics)."
  @spec lock_path(String.t()) :: String.t()
  def lock_path(state_root), do: Path.join(state_root, @lock_name)

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts), do: {:ok, %{state_root: Keyword.get(opts, :state_root, Workstation.Core.EngineState.state_root())}}

  @impl true
  def handle_call({:with_lock, purpose, fun}, _from, state) do
    case acquire_lock(state.state_root, purpose) do
      {:ok, token, path} ->
        try do
          {:reply, fun.(), state}
        after
          release_lock(path, token)
        end

      {:error, {:locked, _owner, _path}} = locked ->
        {:reply, locked, state}
    end
  end

  def handle_call({:acquire, purpose}, _from, state) do
    case acquire_lock(state.state_root, purpose) do
      {:ok, token, path} -> {:reply, {:ok, token, path}, state}
      {:error, {:locked, _, _}} = locked -> {:reply, locked, state}
    end
  end

  def handle_call({:release, token}, _from, state) do
    {:reply, release_lock(lock_path(state.state_root), token), state}
  end

  # Exclusive create, mode 0600, body = owner metadata + token, never
  # stolen: the exact `Workstation.Core.ApplyLock` contract, shared with the
  # one-shot CLI driver so both callers race on one filesystem fact.
  defp acquire_lock(state_root, purpose), do: ApplyLock.acquire(state_root, purpose)

  defp release_lock(path, token), do: ApplyLock.release(path, token)
end
