defmodule Workstation.Daemon.Boot do
  @moduledoc """
  The resident daemon entrypoint: `workstation daemon`.

  The daemon application deliberately carries no `mod:` (a resident
  listener must never auto-boot from `mix test`/`mix run` against the
  ambient HOME), so the tree is started HERE, explicitly, from the CLI verb:
  start the supervisor tree under the resolved home, then park the calling
  process forever. The release VM stays up serving the socket until it is
  stopped (`workstation daemon stop` — the `daemon.stop` op through
  `Workstation.Daemon.Shutdown`) or killed.

  `ensure-daemon` in the CLI client spawns exactly this verb, detached from
  the same release binary, and waits for the socket handshake.
  """

  require Logger

  alias Workstation.Core.EngineState
  alias Workstation.Daemon.Application
  alias Workstation.Daemon.Listener

  @doc """
  Start the daemon tree and park. Returns only on a start failure —
  `{:error, {:already_running, socket_path}}` when another daemon owns the
  socket, `{:error, {:peercred_unavailable, why}}` when the platform cannot
  authenticate peers.
  """
  @spec run() :: :ok | {:error, term()}
  def run do
    # The resident daemon opts IN to the update-availability check (the
    # status wire's `update` field and the `update.check` op resolve the
    # engine repo for real). Tests boot the supervisor spec directly and
    # never opt in, so a test tree cannot fire an unplanned network query.
    # (Elixir.Application spelled out: this module aliases the daemon's own
    # Application tree module.)
    Elixir.Application.put_env(:daemon, :update_check, true)

    # The same tree the OTP callback and the tests boot: supervisor_spec/0
    # is the single source of the rest_for_one wiring (same name, same
    # order) — started here directly because this tree outlives no
    # application master: the park() below is its keeper.
    case Supervisor.start_link(Application.children(),
           strategy: :rest_for_one,
           name: Workstation.Daemon.Supervisor
         ) do
      {:ok, _supervisor} ->
        Logger.info("workstation daemon serving #{EngineState.home()}")
        park()

      # Belt-and-braces refusal: the Registry pre-check in the CLI already
      # refuses a served home; this arm covers a direct in-VM double boot.
      {:error, {:already_started, _supervisor}} ->
        {:error, {:already_running, Listener.socket_path(EngineState.home())}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Park forever, draining the mailbox: the VM's permanent applications
  # (daemon tree included) keep the release alive while this process
  # breathes. Messages are consumed, never acted on — lifecycle belongs to
  # the supervisor and to `daemon stop`.
  defp park do
    Process.flag(:trap_exit, true)

    # Drain-and-sleep forever: the mailbox is consumed (drained by the
    # trap_exit flag + selective receive), never acted on — lifecycle
    # belongs to the supervisor and to `daemon stop`.
    receive do
      _message -> park()
    after
      3_600_000 -> park()
    end
  end
end
