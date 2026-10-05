defmodule Workstation.Daemon.CapabilityRegistry do
  @moduledoc """
  Holds the assembled capability snapshot served by the `hello` handshake.

  The view is captured from `Workstation.Daemon.Protocol.capabilities/0` —
  itself derived from the compile-time `Workstation.Daemon.Capabilities`
  registry — at boot. Keeping the snapshot in a process means every session
  answers hello from one consistent view for the daemon's lifetime.

  Pubsub (`sub/unsub/pub` with exclusive domain ownership) lives in
  `Workstation.Daemon.Overlay`; this module has no event-delivery role.
  """

  use GenServer

  alias Workstation.Daemon.Protocol

  @typedoc "Registry state: one immutable capability snapshot."
  @type state :: %{capabilities: map()}

  @doc "Registry process name (singleton per daemon)."
  @spec registry_name() :: atom()
  def registry_name, do: __MODULE__

  @doc "The advertised capability map served by the hello handshake."
  @spec capabilities() :: map()
  def capabilities, do: GenServer.call(registry_name(), :capabilities)

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: registry_name())
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{capabilities: Protocol.capabilities()}}

  @impl GenServer
  def handle_call(:capabilities, _from, state), do: {:reply, state.capabilities, state}
end
