defmodule Workstation.Daemon.Events do
  @moduledoc """
  Progress events for in-flight ops — the daemon's live-streaming half.

  An op that takes perceptible time (the lifecycle chain, apply) publishes
  structured progress on the EventBus `:op` topic; the owning session
  forwards matching events to the connected client as `{"event": ...}`
  frames, stamped with a per-stream `seq`. This is what gives the TUI its
  LiveView feel and the headless CLI its event-driven lines: screens and
  runners RENDER EVENTS, they do not drive steps themselves.

  Wire vocabulary (string-keyed maps, JSON-ready — every key the frames
  carry):

    * `%{"type" => "run.started", "op" => op, ...}` — the op began;
    * `%{"type" => "step.started", "step" => step}` — one lifecycle step;
    * `%{"type" => "step.done", "step" => step, "ok" => bool,
       "duration_ms" => ms, ("detail" => msg)}` — the step settled;
    * `%{"type" => "run.log", "level" => level, "line" => line}` —
      operator-readable progress notes (identifiers only, never params);
    * `%{"type" => "run.finished", "outcome" => "ok" | "failed" | "aborted",
       ("error" => msg)}` — the op settled.

  Every event also carries the `op_ref` token that scopes it to one op
  run; clients token-guard on it (events from other sessions' ops are
  invisible to a stream because the session filters, and stale trailing
  frames are dropped by the token check on the client side).

  Abort: an op task registers itself under its `op_ref` in the
  `Workstation.Daemon.OpRegistry`, so ANY session can deliver an
  `op.abort` (the `Workstation.Daemon.Events.abort/1` lookup). The task
  checks `aborted?/1` at its own step boundaries — a boundary is the only
  honest cancellation point for a lock-holding mutation chain, so abort is
  Cooperative-at-the-next-step-boundary, never a kill. The event stream
  reports the outcome as `"aborted"`.
  """

  alias Workstation.Daemon.EventBus

  @type op_ref :: String.t()

  @doc "A fresh op-scoped token: unique per daemon generation, opaque to clients."
  @spec new_ref() :: op_ref
  def new_ref, do: "op-" <> Integer.to_string(System.unique_integer([:positive]))

  @doc """
  Publish one progress event on the `:op` topic. `extra` merges over the
  `op_ref`/`type` envelope; values must be JSON scalars (string-keyed).
  """
  @spec emit(op_ref(), String.t(), map()) :: :ok
  def emit(op_ref, type, extra \\ %{}) when is_binary(op_ref) and is_binary(type) and is_map(extra) do
    EventBus.publish(:op, Map.merge(%{"op_ref" => op_ref, "type" => type}, extra))
  end

  @doc "Register the calling process as the op's abort target."
  @spec register(op_ref()) :: :ok
  def register(op_ref) when is_binary(op_ref) do
    {:ok, _} = Registry.register(Workstation.Daemon.OpRegistry, op_ref, :ok)
    :ok
  end

  @doc "Drop the calling process's abort registration (idempotent)."
  @spec unregister(op_ref()) :: :ok
  def unregister(op_ref) when is_binary(op_ref) do
    Registry.unregister(Workstation.Daemon.OpRegistry, op_ref)
    :ok
  end

  @doc """
  Deliver an abort to the op named by `op_ref` (any session may). Returns
  whether a live op task was found — the op still decides at its next
  boundary whether it can stop.
  """
  @spec abort(op_ref()) :: boolean()
  def abort(op_ref) when is_binary(op_ref) do
    case Registry.lookup(Workstation.Daemon.OpRegistry, op_ref) do
      [] ->
        false

      pids ->
        Enum.each(pids, &send(&1, {:op_abort, op_ref}))
        true
    end
  end

  @doc """
  Whether an abort arrived for this op — checked by the op task AT STEP
  BOUNDARIES (never mid-step: a cancelled mutation must not leave a half
  applied generation). Drains exactly the abort signal, leaving any other
  mailbox traffic alone.
  """
  @spec aborted?(op_ref()) :: boolean()
  def aborted?(op_ref) when is_binary(op_ref) do
    receive do
      {:op_abort, ^op_ref} -> true
    after
      0 -> false
    end
  end

  @doc """
  Run one lifecycle step inside the event stream: emits `step.started`,
  times the body, emits `step.done` with the duration (and the verbatim
  error detail on failure), and returns `{:ok, record, duration_ms}` or
  `{:error, code, message, duration_ms}`.
  """
  @spec step(op_ref(), String.t(), (-> {:ok, map()} | {:error, String.t(), String.t()})) ::
          {:ok, map(), non_neg_integer()} | {:error, String.t(), String.t(), non_neg_integer()}
  def step(op_ref, name, fun) when is_binary(op_ref) and is_binary(name) and is_function(fun, 0) do
    emit(op_ref, "step.started", %{"step" => name})
    started = now_ms()

    result =
      try do
        fun.()
      rescue
        error -> {:error, "step_failed", Exception.message(error)}
      end

    duration = now_ms() - started

    case result do
      {:ok, record} ->
        emit(op_ref, "step.done", %{"step" => name, "ok" => true, "duration_ms" => duration})
        {:ok, record, duration}

      {:error, code, message} ->
        emit(op_ref, "step.done", %{
          "step" => name,
          "ok" => false,
          "duration_ms" => duration,
          "detail" => "#{code}: #{message}"
        })

        {:error, code, message, duration}
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
