defmodule Workstation.Daemon.Overlay do
  @moduledoc """
  Domain-ownership primitive: `claim/release/pub` over named domains with
  exclusive ownership, plus a domain fanout for followers.

  A process claims a domain name (`"theme"`, `"apply"`, …) as its sole
  owner; a second claimant for the same domain is refused
  (`{:error, :taken}`). `pub/2` delivers an event to the current owner of a
  domain, best-effort: ownerless domains silently drop the direct delivery,
  and crashed owners are reaped via monitor so their domains free up
  automatically.

  Every published event ALSO fans out on the event bus under the
  `{:domain, name}` topic (`Workstation.Daemon.EventBus`), so processes that
  need to FOLLOW a domain without owning it — theme panels, test harnesses —
  subscribe there instead of contending for ownership. Fanout is additive:
  the owner-direct contract above is unchanged, and a missing event-bus
  registry (the overlay is never started without it in the daemon tree)
  fails the pub loudly rather than silently halving delivery.

  Domain-specific knowledge lives with the domain's capability (for example
  `Workstation.Daemon.Capabilities.Theme` owns the `"theme"` domain and
  publishes resolved themes on it). This module carries none.
  """

  use GenServer

  alias Workstation.Daemon.EventBus

  @typedoc "Domain names are plain strings, unique across the overlay."
  @type domain :: String.t()

  @typedoc "Overlay state: domain -> owner pid, plus reverse monitors."
  @type state :: %{owners: %{domain() => pid()}, monitors: %{reference() => domain()}}

  @doc "Overlay process name (singleton per daemon)."
  @spec overlay_name() :: atom()
  def overlay_name, do: __MODULE__

  # --- ownership API --------------------------------------------------------

  @doc """
  Claim `pid` (default: caller) as the exclusive owner of `domain`.
  `:ok` when the domain is free or already owned by the same pid,
  `{:error, :taken}` when another process owns it.
  """
  @spec claim(domain(), pid()) :: :ok | {:error, :taken}
  def claim(domain, pid \\ self()) when is_binary(domain) and is_pid(pid) do
    GenServer.call(overlay_name(), {:claim, domain, pid})
  end

  @doc "Release `pid`'s ownership of `domain`. Idempotent."
  @spec release(domain(), pid()) :: :ok
  def release(domain, pid \\ self()) when is_binary(domain) and is_pid(pid) do
    GenServer.call(overlay_name(), {:release, domain, pid})
  end

  @doc """
  Publish `event` on `domain`: direct delivery to its current owner, if
  any, plus fanout to `{:domain, domain}` event-bus subscribers. Direct
  delivery is best-effort but ordered: the call returns after the event is
  in the owner's mailbox, so mailbox order equals publish order. A domain
  without an owner drops the direct delivery; followers still see the
  fanout.
  """
  @spec pub(domain(), term()) :: :ok
  def pub(domain, event) when is_binary(domain) do
    GenServer.call(overlay_name(), {:pub, domain, event})
  end

  @doc "Domains with a live owner right now, sorted."
  @spec owned_domains() :: [domain()]
  def owned_domains, do: GenServer.call(overlay_name(), :owned_domains)

  # -- supervision ------------------------------------------------------------

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: overlay_name())
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{owners: %{}, monitors: %{}}}

  @impl GenServer
  def handle_call({:claim, domain, pid}, _from, state) do
    cond do
      owner = state.owners[domain] ->
        if owner == pid, do: {:reply, :ok, state}, else: {:reply, {:error, :taken}, state}

      true ->
        ref = Process.monitor(pid)
        {:reply, :ok, %{state | owners: Map.put(state.owners, domain, pid), monitors: Map.put(state.monitors, ref, domain)}}
    end
  end

  def handle_call({:release, domain, pid}, _from, state) do
    case state.owners[domain] do
      ^pid ->
        {ref, monitors} =
          Enum.find_value(state.monitors, {nil, state.monitors}, fn {r, d} ->
            if d == domain, do: {r, Map.delete(state.monitors, r)}
          end)

        if ref, do: Process.demonitor(ref, [:flush])
        {:reply, :ok, %{state | owners: Map.delete(state.owners, domain), monitors: monitors}}

      _other ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:owned_domains, _from, state),
    do: {:reply, state.owners |> Map.keys() |> Enum.sort(), state}

  @impl GenServer
  def handle_call({:pub, domain, event}, _from, state) do
    case state.owners[domain] do
      nil -> :ok
      pid -> send(pid, event)
    end

    # Domain fanout for followers (see the moduledoc): same event, the
    # event bus' standard {:daemon_event, topic, event} envelope.
    EventBus.publish({:domain, domain}, event)

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {domain, monitors} = Map.pop(state.monitors, ref)
    {:noreply, %{state | monitors: monitors, owners: Map.delete(state.owners, domain)}}
  end
end
