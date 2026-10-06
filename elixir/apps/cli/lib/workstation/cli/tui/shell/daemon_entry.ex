defmodule Workstation.CLI.TUI.Shell.DaemonEntry do
  @moduledoc false

  # Boot seam between the router's bare-verb branch and the TUI shell:
  # make sure a daemon serves the destination home, then hand control to
  # the shell. All of the probing/spawning/waiting reuses the client's own
  # path (DaemonClient.call/3 already ensures — probes, spawns detached,
  # awaits the handshake), so the TUI cannot drift from what
  # `workstation status` does. Success closes the probe socket and boots;
  # failure reports through the router's shared stderr + exit-code
  # contract (4 — engine failure, daemon unavailable).

  alias Workstation.CLI.DaemonClient
  alias Workstation.CLI.Router
  alias Workstation.CLI.TUI.Shell

  @probe_timeout_ms 15_000

  @spec run(keyword()) :: no_return()
  def run(opts) do
    destination = Keyword.fetch!(opts, :destination)

    case DaemonClient.call("status.run", %{}, home: destination, timeout_ms: @probe_timeout_ms) do
      {:ok, _status} ->
        Shell.run(Keyword.put(opts, :home, destination))

      {:error, {:daemon_unavailable, message}} ->
        Router.fail(4, "error: daemon_unavailable: #{message}")

      {:error, {code, message}} when is_atom(code) or is_binary(code) ->
        Router.fail(4, "error: #{code}: #{message}")

      {:error, code, message} ->
        Router.fail(4, "error: #{code}: #{message}")
    end
  end
end
