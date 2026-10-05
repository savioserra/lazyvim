defmodule Workstation.Daemon.Capabilities.Update do
  @moduledoc """
  Update capability: serves `update.run`, delegating the lifecycle step to
  the c2 update orchestrator (`Workstation.Daemon.Update`).
  """

  use Workstation.Daemon.Capability

  @op "update.run"

  @lifecycle_steps Zoi.enum(["pull", "bootstrap", "apply", "sync", "verify"])

  @update_run_params_schema Zoi.object(%{"step" => @lifecycle_steps},
                              unrecognized_keys: :error
                            )

  @impl true
  def ops, do: [@op]

  @impl true
  def schema(@op), do: @update_run_params_schema

  @impl true
  def handle(@op, %{"step" => step}, _ctx) do
    Workstation.Daemon.Update.run(step)
  end
end
