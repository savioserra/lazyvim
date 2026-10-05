defmodule Workstation.Daemon.Capabilities.Apply do
  @moduledoc """
  Apply capability: serves `apply.run` — one orchestrated real-host apply
  generation over the c1 apply engine (`Workstation.Daemon.Apply`).

  Mutation stays behind the graduation gate (`Workstation.Daemon.Apply.enabled?/0`,
  compile-time OFF): a refused op still takes the apply lock and answers
  with the canonical not-graduated message, so refusal is serialized against
  any concurrent lifecycle work instead of racing it.
  """

  use Workstation.Daemon.Capability

  alias Workstation.Daemon.ApplyOrchestrator

  @op "apply.run"

  @apply_run_params_schema Zoi.object(
                             %{
                               "generation" => Zoi.string(min_length: 1),
                               "entries" => Zoi.array(Zoi.map(Zoi.string(), Zoi.string()))
                             },
                             unrecognized_keys: :error
                           )

  @impl true
  def ops, do: [@op]

  @impl true
  def schema(@op), do: @apply_run_params_schema

  @impl true
  def handle(@op, %{"generation" => generation}, _ctx) do
    if Workstation.Daemon.Apply.enabled?() do
      Workstation.Daemon.Apply.run(generation)
    else
      lifecycle_op("apply.run generation=#{generation}")
    end
  end

  # Refusal happens inside the lock: the not-graduated answer must serialize
  # against a real apply rather than answering from outside the critical
  # section.
  defp lifecycle_op(purpose) do
    case ApplyOrchestrator.with_lock(purpose, fn ->
           {:error,
            {"not_graduated", Workstation.Daemon.Apply.not_graduated_message()}}
         end) do
      {:error, {:locked, owner, _path}} ->
        {:error, {"locked", "apply lock held by #{owner}"}}

      result ->
        result
    end
  end
end
