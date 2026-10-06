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
  screen's request map (generation + entry rows, plus an optional `events`
  sink — a `(daemon event map) -> any` callback receiving the op's live
  progress stream); the generation rides to the daemon as the requested
  generation, so a confirm applies exactly the state the operator saw or
  refuses as stale.
  """
  @spec apply_executor(map()) :: :ok | {:error, String.t()}
  def apply_executor(%{"generation" => generation, "entries" => entries} = request)
      when is_binary(generation) and is_list(entries) do
    fold(
      DaemonClient.call(
        "apply.run",
        %{"generation" => generation, "entries" => entries},
        on_event: events_pipe(request),
        timeout_ms: @lifecycle_timeout_ms
      )
    )
  end

  def apply_executor(_payload), do: {:error, "malformed apply request"}

  @doc """
  Update executor: ONE daemon op for the whole step sub-chain (the daemon
  owns the locks and the step sequencing; the screen renders its event
  stream). The optional `events` sink is the same callback contract as the
  apply executor's — it is how the screen receives
  step.started/step.done transitions instead of driving steps itself.
  """
  @spec update_executor(map()) :: :ok | {:error, String.t()}
  def update_executor(%{"steps" => steps} = request) when is_list(steps) do
    fold(update_wire_executor(request))
  end

  def update_executor(_payload), do: {:error, "malformed update request"}

  @doc """
  The UNFOLDED update executor for the headless runner: the raw
  `DaemonClient.call` shapes (`{:ok, record}` with the handoff marker, or
  the tagged refusal pairs) — `Workstation.CLI.Plain.run_update` must see
  the record to drive the release handoff, while the TUI screens consume
  the folded `:ok | {:error, message}` shape (`update_executor/1`).
  """
  @spec update_wire_executor(map()) ::
          {:ok, map()}
          | {:error, {atom() | String.t(), String.t()} | String.t()}
  def update_wire_executor(%{"steps" => steps} = request) when is_list(steps) do
    DaemonClient.call("update.run", %{"steps" => steps}, on_event: events_pipe(request), timeout_ms: @lifecycle_timeout_ms)
  end

  def update_wire_executor(_payload), do: {:error, {"invalid_params", "malformed update request"}}

  # The events sink arrives inside the request map (an optional
  # `(event) -> any` fun); the daemon streams op progress frames and each
  # is handed to the sink verbatim. Absent sink = drop (headless verbs
  # without rendering callers).
  defp events_pipe(request) do
    case request["events"] do
      fun when is_function(fun, 1) -> fun
      _other -> fn _event -> :ok end
    end
  end

  @doc """
  Update-availability check executor (supervisor-directed scope): one
  `update.check` op — read-only, daemon-side, TTL-cached — returning the
  raw verdict for `Workstation.CLI.TUI.UpdateHint` to fold. The screens
  fire it asynchronously; transport failures ride the same result shape
  and fold to silence there.
  """
  @spec update_check_executor() :: {:ok, map()} | {:error, String.t()}
  def update_check_executor do
    case DaemonClient.call("update.check", %{}) do
      {:ok, verdict} when is_map(verdict) -> {:ok, verdict}
      {:error, {tag, message}} when is_atom(tag) -> {:error, message}
      {:error, {code, message}} when is_binary(code) -> {:error, "#{code}: #{message}"}
      {:error, code, message} -> {:error, "#{code}: #{message}"}
    end
  end

  @doc """
  Abort executor: forwards `op.abort` for an in-flight stream token. The
  daemon cancels the op at its NEXT STEP BOUNDARY (never mid-step) and the
  chain settles as aborted; best-effort — a racing finish is an error
  value, never a crash.
  """
  @spec abort_executor(String.t()) :: :ok | {:error, String.t()}
  def abort_executor(op_ref) when is_binary(op_ref) do
    DaemonClient.abort(op_ref)
  end

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
