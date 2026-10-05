defmodule Workstation.Daemon.EventBus do
  @moduledoc """
  Daemon-wide event fanout on a `Registry` with `:duplicate` keys.

  Why a registry and not a GenServer broadcaster: sessions publish lifecycle
  and op events from many processes and every subscriber gets its own copy
  synchronously in its own mailbox; a central broadcaster would serialize
  sessions on it and turn one slow subscriber into daemon-wide backpressure.
  Topics are static (`:session`, `:op`, `:apply`).

  Events carry identifiers and op NAMES only — never request params — so a
  subscriber cannot become a secret leak even though params are scrubbed from
  every log line as well. The supervised child is the registry itself; this
  module holds only the subscribe/publish contract.
  """

  @type topic :: :session | :op | :apply
  @type event :: term()

  @doc false
  def child_spec(_opts) do
    # The supervised child is the registry itself: fanout survives module
    # reloads and there is no broker process to crash or bottleneck.
    Supervisor.child_spec(
      {Registry, keys: :duplicate, name: Workstation.Daemon.EventBus, partitions: System.schedulers_online()},
      id: __MODULE__
    )
  end

  @doc "Receive `{topic, event}` messages for `topic` from now on."
  @spec subscribe(topic()) :: :ok
  def subscribe(topic) do
    {:ok, _} = Registry.register(Workstation.Daemon.EventBus, topic, :ok)
    :ok
  end

  @doc "Deliver `event` to every current subscriber of `topic`."
  @spec publish(topic(), event()) :: :ok
  def publish(topic, event) do
    Registry.dispatch(Workstation.Daemon.EventBus, topic, fn subscribers ->
      Enum.each(subscribers, fn {pid, :ok} -> send(pid, {:daemon_event, topic, event}) end)
    end)
  end
end
