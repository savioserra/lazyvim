defmodule Workstation.CLI.ControlVerbs do
  @moduledoc """
  The release dispatcher's control verbs — the single source of truth the
  release step (`Workstation.Umbrella.MixProject.cli_dispatch_step/1`)
  compiles into the shipped `bin/workstation` shim. Verbs on this list
  forward to the release control script (`bin/workstation_ctl`, the OTP
  lifecycle surface: start/stop/pid/rpc/eval); every other verb boots the
  release VM into `Workstation.CLI.Router.main/1`.

  `daemon` deliberately IS NOT a control verb. The Router owns the daemon
  surface: the bare `workstation daemon` is the foreground boot the
  ensure-daemon spawn targets (`Workstation.CLI.DaemonClient` spawns
  `<release>/bin/workstation daemon`, nohup'd with stdio into the daemon
  log), so the dispatcher must hand it to the Router — forwarding it to
  `workstation_ctl daemon` instead starts a detached OTP daemon VM that
  never runs `Workstation.Daemon.Boot.run` and never binds the state
  socket, stranding every ensure-spawn on the handshake timeout (the
  2026-10-06 hang). Raw OTP daemon mode stays reachable for ops directly
  as `bin/workstation_ctl daemon`.
  """

  @verbs ~w(start start_iex daemon_iex eval rpc remote restart stop pid version)

  @doc """
  Verbs the release dispatcher forwards to `bin/workstation_ctl` instead
  of the Router. `daemon` must never appear here (see the moduledoc).
  """
  @spec list() :: [String.t(), ...]
  def list, do: @verbs
end
