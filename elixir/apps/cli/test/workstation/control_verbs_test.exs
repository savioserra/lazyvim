defmodule Workstation.CLI.ControlVerbsTest do
  @moduledoc """
  The release dispatcher's verb contract: `daemon` must never be a control
  verb. The ensure-daemon spawn targets `<release>/bin/workstation daemon`
  and needs the CLI Router (the foreground `Workstation.Daemon.Boot.run`
  boot); a control-verb `daemon` forwards to `bin/workstation_ctl daemon` —
  a detached OTP daemon VM that never boots the daemon tree and never binds
  the state socket, timing out every ensure-spawn (the 2026-10-06 hang).
  """

  use ExUnit.Case, async: true

  test "the dispatcher forwards only OTP lifecycle verbs, never daemon" do
    verbs = Workstation.CLI.ControlVerbs.list()

    refute "daemon" in verbs,
           "the Router owns `workstation daemon` (the ensure-daemon spawn target); " <>
             "a control-verb daemon strands the spawn on an idle OTP daemon VM"

    for verb <- ~w(start start_iex daemon_iex eval rpc remote restart stop pid version) do
      assert verb in verbs, "OTP lifecycle verb #{verb} must stay a control verb"
    end
  end
end
