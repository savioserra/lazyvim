defmodule Workstation.CLI.ControlVerbs do
  @moduledoc """
  The release dispatcher's control verbs — the single source of truth the
  release step (`Workstation.Umbrella.MixProject.cli_dispatch_step/1`)
  compiles into the shipped `bin/workstation` shim. Verbs on this list
  forward to the release control script (`bin/workstation_ctl`, the OTP
  lifecycle surface: start/stop/pid/rpc/eval); every other verb boots the
  release VM into `Workstation.CLI.Router.main/1`.
  """

  @verbs ~w(start start_iex daemon_iex eval rpc remote restart stop pid version)

  @doc """
  Verbs the release dispatcher forwards to `bin/workstation_ctl` instead
  of the Router.
  """
  @spec list() :: [String.t(), ...]
  def list, do: @verbs
end
