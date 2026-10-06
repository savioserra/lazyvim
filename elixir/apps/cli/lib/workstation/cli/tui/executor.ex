defmodule Workstation.CLI.TUI.Executor do
  @moduledoc """
  The production executors behind the apply and update screens: the daemon
  client (`Workstation.CLI.DaemonClient`), the same ops the headless CLI
  sends — the daemon is the only mutation engine, so the screen and the
  plain runner speak the identical wire surface.

  The screens own interaction only; the executor is the mutation seam they
  invoke on confirm. This module is that seam's production answer: it hands
  the confirmed payload to the daemon as one op — the daemon's orchestrator
  lock serializes the run, the journal baseline refuses a screen that went
  stale between render and confirm, and an identical desired generation is
  an idempotent no-op.

  Fail-closed in one direction: any precondition, lock, daemon, or engine
  failure becomes `{:error, message}` carrying the verbatim operator
  message — never `:ok`, never a stacktrace.
  """

  alias Workstation.CLI.DaemonClient

  # Lifecycle ops queue behind in-flight runs and engine steps take real
  # time; the op budget is minutes, not the read default.
  @lifecycle_timeout_ms 600_000

  @doc """
  Apply executor: the confirm path of the apply screen. The payload is the
  screen's request map (generation + entry rows); the generation rides to
  the daemon as the requested generation, so a confirm applies exactly the
  state the operator saw or refuses as stale.
  """
  @spec apply_executor(map()) :: :ok | {:error, String.t()}
  def apply_executor(%{"generation" => generation, "entries" => entries})
      when is_binary(generation) and is_list(entries) do
    fold(
      DaemonClient.call(
        "apply.run",
        %{"generation" => generation, "entries" => entries},
        timeout_ms: @lifecycle_timeout_ms
      )
    )
  end

  def apply_executor(_payload), do: {:error, "malformed apply request"}

  @doc """
  Update executor: one lifecycle step per request (the update screen's
  abort-on-first-failure semantics map one op onto one chain link).
  """
  @spec update_executor(map()) :: :ok | {:error, String.t()}
  def update_executor(%{"step" => step}) when is_binary(step) do
    fold(DaemonClient.call("update.run", %{"step" => step}, timeout_ms: @lifecycle_timeout_ms))
  end

  def update_executor(_payload), do: {:error, "malformed update request"}

  # Daemon op results fold to the screens' two-value contract. Daemon
  # transport failures are atom-tagged pairs, matched before the wire's
  # binary-code pairs; every message is operator-facing verbatim.
  defp fold({:ok, _record}), do: :ok
  defp fold({:error, {tag, message}}) when is_atom(tag), do: {:error, message}
  # Wire op refusals carry a binary code pair (`locked`, `invalid_params`,
  # `apply_refused`, ...); transport failures are the atom-tagged pairs
  # above. Both fold to the screens' flat message, code prefixed.
  defp fold({:error, {code, message}}) when is_binary(code), do: {:error, "#{code}: #{message}"}
  defp fold({:error, code, message}), do: {:error, "#{code}: #{message}"}
end
