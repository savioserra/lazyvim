defmodule Workstation.CLI.TUI.Executor do
  @moduledoc """
  The production executors behind the apply and update screens: the one-shot
  in-process engine (`Workstation.CLI.Engine`), the same lock-serialized
  mutation path the headless CLI takes.

  The screens own interaction only; the executor is the mutation seam they
  invoke on confirm. This module is that seam's production answer: it hands
  the confirmed payload to the engine driver — the apply lock serializes the
  run, the journal baseline refuses a screen that went stale between render
  and confirm, and an identical desired generation is an idempotent no-op.

  Fail-closed in one direction: any precondition, lock, or engine failure
  becomes `{:error, message}` carrying the engine's verbatim operator
  message — never `:ok`, never a stacktrace.
  """

  alias Workstation.CLI.Engine

  @doc """
  Apply executor: the confirm path of the apply screen. The payload is the
  screen's request map (generation + entry rows); the generation rides to
  the engine as the requested generation, so a confirm applies exactly the
  state the operator saw or refuses as stale.
  """
  @spec apply_executor(map()) :: :ok | {:error, String.t()}
  def apply_executor(%{"generation" => generation, "entries" => entries})
      when is_binary(generation) and is_list(entries) do
    fold(Engine.apply(requested_generation: generation))
  end

  def apply_executor(_payload), do: {:error, "malformed apply request"}

  @doc """
  Update executor: one lifecycle step per request (the update screen's
  abort-on-first-failure semantics map one op onto one chain link).
  """
  @spec update_executor(map()) :: :ok | {:error, String.t()}
  def update_executor(%{"step" => step}) when is_binary(step) do
    fold(Engine.run_step(step, []))
  end

  def update_executor(_payload), do: {:error, "malformed update request"}

  defp fold({:ok, _record}), do: :ok
  defp fold({:error, _code, message}), do: {:error, message}
end
