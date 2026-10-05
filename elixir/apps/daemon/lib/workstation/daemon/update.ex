defmodule Workstation.Daemon.Update do
  @moduledoc """
  The daemon's update-lifecycle orchestrator: one lifecycle step per
  `update.run` request, every step under the SAME exclusive apply lock the
  applier and the Lua one-shot serialize through, abort-on-first-failure
  decided by the caller (the TUI chain marks the remaining steps skipped;
  the daemon answers one step at a time, honestly).

  Step wiring (semantics in `Workstation.Core.Update.*`):

  * `pull` — checked fast-forward of the engine checkout (network-bound);
  * `bootstrap` — verified pinned runtime + backend + public launcher;
  * `apply` — delegates to the c1 executor (`Workstation.Daemon.Apply.run_current/1`)
    while holding this lock;
  * `sync` — re-collect + plan reconciliation against the journal (read-only);
  * `verify` — launcher + per-package journal fingerprint verification (read-only).

  The graduation gate is the SAME feature flag as the applier's
  (`Workstation.Daemon.Apply.enabled?/0`, compile-time OFF): it gates the
  MUTATION steps (pull, bootstrap, apply) off until the graduation lane
  flips it. The read-only steps serve regardless — they are the graduated
  read surface (collect/plan/verify) reached through the update op — so the
  flip opens the mutating steps without a wire change, exactly like the
  applier's own gate.

  Like the gated applier, the gate refusal runs INSIDE the lock: the
  serialization path stays exercised and lock contention still reports the
  recorded owner, whatever the gate state.
  """

  alias Workstation.Core.Update.{Bootstrap, Pull, Sync, Verify}
  alias Workstation.Daemon.{Apply, ApplyOrchestrator}

  @mutation_steps ["pull", "bootstrap", "apply"]

  @doc "Lifecycle steps in execution order (docs/capabilities.md)."
  @spec steps() :: [String.t()]
  defdelegate steps(), to: Workstation.Core.Update

  @doc "The steps the graduation flag gates off until the applier graduates."
  @spec mutation_step?(String.t()) :: boolean()
  def mutation_step?(step), do: step in @mutation_steps

  @doc """
  Run one lifecycle step under the orchestrator's exclusive apply lock.
  Returns `{:ok, record}` with the step's status record, or an error tuple:
  `{"not_graduated", _}` for gated mutation steps, `{"locked", _}` under
  contention, `{"update_failed", _}` with the verbatim engine message when
  a served step fails.

  Options: `:home` and `:collector` (sandbox catalog injection, the
  applier's contract), plus the engine-root/bootstrap options the core
  steps accept.
  """
  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, {String.t(), String.t()}}
  def run(step, opts \\ []) when is_binary(step) and is_list(opts) do
    result =
      ApplyOrchestrator.with_lock("update.run step=#{step}", fn ->
        cond do
          mutation_step?(step) and not Apply.enabled?() ->
            {:error, {"not_graduated", Apply.not_graduated_message()}}

          true ->
            execute(step, opts)
        end
      end)

    case result do
      {:error, {:locked, owner, _path}} -> {:error, {"locked", "apply lock held by #{owner}"}}
      other -> other
    end
  end

  defp execute("pull", opts), do: guarded(fn -> Pull.run(opts) end)
  defp execute("bootstrap", opts), do: guarded(fn -> Bootstrap.run(opts) end)
  defp execute("apply", opts), do: guarded(fn -> Apply.run_current(opts) end)
  defp execute("sync", opts), do: guarded(fn -> Sync.run(opts) end)
  defp execute("verify", opts), do: guarded(fn -> Verify.run(opts) end)

  # A step's engine failure surfaces verbatim: the message is the
  # operator-facing truth, and the step name is already in it (every core
  # update step prefixes its failures). The :exit catch arm matters as much
  # as the rescue: this fun runs INSIDE the orchestrator's with_lock, so an
  # uncaught EXIT would kill the orchestrator process (the caller receives
  # an unrescuable EXIT and the socket dies) instead of failing the one
  # operation.
  defp guarded(fun) do
    fun.()
  rescue
    error -> {:error, {"update_failed", Exception.message(error)}}
  catch
    :exit, reason -> {:error, {"update_failed", "step aborted: " <> inspect(reason)}}
  end
end
