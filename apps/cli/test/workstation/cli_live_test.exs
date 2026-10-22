defmodule Workstation.CLI.LiveTest do
  @moduledoc """
  The live reads against a REAL in-process daemon tree — the client/daemon
  split's end-to-end contract for the verbs that have no offline form.

  Migrated from `Workstation.CLITest` (engine work, M1): live reads route
  through `status.run` / `plan.run` / `diff.run`, so these tests need a
  daemon pinned to the sandbox home and must never run concurrent with the
  async suite (WORKSTATION_HOME and the daemon tree are process-global).
  The write verbs retired with the engine's write plane; mutation lives in
  the nix substrate's workstation-switch drivers.
  """

  use ExUnit.Case, async: false

  # Fixture homes are cross-VM collision-proof: `System.unique_integer/1`
  # restarts its sequence in every `mix test` VM, so a home that outlives its
  # run (a killed run's leftovers) is re-drawn verbatim by a later one. The
  # boot millisecond in base36 never repeats across VMs, any same-named
  # leftover is swept before use, and the home is removed on exit (the full
  # note lives in apps/daemon/test/workstation/daemon/generation_test.exs).
  defp unique_home(prefix) do
    token = Integer.to_string(:os.system_time(:millisecond), 36)
    home = Path.join(System.tmp_dir!(), "#{prefix}-#{token}")

    File.rm_rf!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    home
  end


  alias Workstation.CLI.Router
  alias Workstation.Daemon.Listener

  setup do
    home = unique_home("ws-cli-live")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
    end)

    start_supervised!(Workstation.Daemon.Application.supervisor_spec())
    wait_for_file(Listener.socket_path())

    %{home: home}
  end

  test "json output is canonical JSON (compact, keys sorted)", %{home: home} do
    {result, output} = capture_main(["json", "status", "--home", home])

    assert result == :ok
    wire = Jason.decode!(output)
    assert String.trim_trailing(output, "\n") == canonical_json(wire)
  end

  test "status evaluates the live home through the native catalog", %{home: home} do
    {status_result, status_output} = capture_main(["json", "status", "--home", home])
    assert status_result == :ok

    status_wire = Jason.decode!(status_output)

    assert %{
             "schema" => "workstation.status.v1",
             "engine" => %{"mode" => "elixir"},
             "packages" => packages,
             "graph_order" => graph_order
           } = status_wire

    # An empty test home still composes the full native catalog: packages
    # live in the engine checkout, the home is only the destination.
    assert is_list(packages) and packages != []
    assert Enum.all?(packages, &is_map_key(&1, "id"))
    assert is_list(graph_order) and graph_order != []
  end

  # Regression (final-gate P1): a fresh home's capabilities envelope can
  # carry nil-able fields — a file row's `mode` — and the canonical-JSON
  # encoder crashed with "canonical JSON cannot encode nil" exactly on
  # this verb. The encoder now emits the JSON `null` literal for nil, so
  # the fresh-home read is rc 0 with the same envelope shape. (The
  # envelope's old `applied_generation` nil field retired with the write
  # plane's journal.)
  test "capabilities --json answers rc 0 on a fresh home (nil fields encode as null)", %{home: home} do
    {result, output} = capture_main(["capabilities", "--json", "--home", home])

    assert result == :ok
    wire = Jason.decode!(output)

    assert %{"schema" => "workstation.capabilities.v1", "domains" => domains} = wire

    # An empty test home still composes the full catalog, so the envelope
    # carries real file rows (the other half of the nil field surface).
    assert is_list(domains) and domains != []

    # The envelope is canonical JSON (compact, keys sorted) — the same
    # bytes-then-decode parity the other live verbs pin.
    assert String.trim_trailing(output, "\n") == canonical_json(wire)
  end

  defp capture_main(argv) do
    me = self()

    {pid, ref} =
      spawn_monitor(fn ->
        output =
          ExUnit.CaptureIO.capture_io(fn ->
            result =
              try do
                Router.main(argv)
                :ok
              catch
                :exit, {:shutdown, code} -> {:shutdown, code}
              end

            send(me, {:main_result, result})
          end)

        send(me, {:main_output, output})
      end)

    result =
      receive do
        {:main_result, result} -> result
        {:DOWN, ^ref, :process, ^pid, reason} -> {:down, reason}
      after
        120_000 -> flunk("router main did not finish")
      end

    output =
      receive do
        {:main_output, output} -> output
      after
        5_000 -> ""
      end

    {result, output}
  end

  defp canonical_json(value) when is_map(value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
    |> Jason.encode!()
  end

  defp canonical_json(value) when is_list(value), do: Jason.encode!(value)

  defp canonical_json(value), do: Jason.encode!(value)

  defp wait_for_file(path, tries \\ 100)

  defp wait_for_file(_path, 0), do: flunk("listener socket never appeared")

  defp wait_for_file(path, tries) do
    if File.exists?(path), do: :ok, else: (Process.sleep(20) && wait_for_file(path, tries - 1))
  end
end
