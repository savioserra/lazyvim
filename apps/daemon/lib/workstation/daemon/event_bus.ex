defmodule Workstation.Daemon.EventBus do
  @moduledoc """
  Daemon-wide event fanout on a `Registry` with `:duplicate` keys.

  Why a registry and not a GenServer broadcaster: sessions publish lifecycle
  and op events from many processes and every subscriber gets its own copy
  synchronously in its own mailbox; a central broadcaster would serialize
  sessions on it and turn one slow subscriber into daemon-wide backpressure.
  Topics come in two families: the static daemon topics (`:session`, `:op`,
  `:apply`) and the dynamic domain fanout family `{:domain, name}` — one
  registry key per overlay domain, fed by `Workstation.Daemon.Overlay.pub/2`
  so processes can FOLLOW a domain's events without claiming its ownership.

  Events carry identifiers and op NAMES only — never request params — so a
  subscriber cannot become a secret leak even though params are scrubbed from
  every log line as well. The supervised child is the registry itself; this
  module holds only the subscribe/publish contract.
  """

  @type topic :: :session | :op | :apply | {:domain, String.t()}
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

  @doc "Stop receiving `{topic, event}` messages (idempotent)."
  @spec unsubscribe(topic()) :: :ok
  def unsubscribe(topic) do
    Registry.unregister(Workstation.Daemon.EventBus, topic)
    :ok
  end

  @doc """
  Deliver `event` to every current subscriber of `topic`.

  Publishing into a bus that is NOT RUNNING (a supervision tree being torn
  down — `:rest_for_one` stops the bus before the sessions, so a session
  draining its last frames can publish into a dead registry) is a no-op,
  not a crash: there is nobody left to owe the event, and a teardown race
  must never surface as a session crash log.
  """
  @spec publish(topic(), event()) :: :ok
  def publish(topic, event) do
    case :erlang.whereis(Workstation.Daemon.EventBus) do
      :undefined ->
        :ok

      _bus ->
        try do
          Registry.dispatch(Workstation.Daemon.EventBus, topic, fn subscribers ->
            Enum.each(subscribers, fn {pid, :ok} -> send(pid, {:daemon_event, topic, event}) end)
          end)
        rescue
          # The bus died between the whereis check and the dispatch (the
          # teardown race, narrowed but not eliminated).
          ArgumentError -> :ok
        end

        :ok
    end
  end
end
