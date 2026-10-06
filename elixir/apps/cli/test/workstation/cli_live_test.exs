defmodule Workstation.CLI.LiveTest do
  @moduledoc """
  The live-read and headless verbs against a REAL in-process daemon tree —
  the client/daemon split's end-to-end contract for the verbs that have no
  offline form.

  Migrated from `Workstation.CLITest` (engine work, M1): live reads route
  through `status.run` / `plan.run` / `diff.run` and the headless apply
  chain drives `plan.run` + `apply.run` over the socket, so these tests
  need a daemon pinned to the sandbox home and must never run concurrent
  with the async suite (WORKSTATION_HOME and the daemon tree are
  process-global). Assertions are carried over verbatim from the
  in-process era; only the transport changed.
  """

  use ExUnit.Case, async: false

  alias Workstation.CLI.{DaemonClient, Router}
  alias Workstation.Daemon.Listener

  setup do
    home = Path.join(System.tmp_dir!(), "ws-cli-live-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
      File.rm_rf!(home)
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

  test "status and diff evaluate the live home through the native catalog", %{home: home} do
    {status_result, status_output} = capture_main(["json", "status", "--home", home])
    assert status_result == :ok

    status_wire = Jason.decode!(status_output)

    assert %{
             "schema" => "workstation.status.v1",
             "engine" => %{"mode" => "elixir"},
             "packages" => packages,
             "graph_order" => graph_order,
             "journal" => nil
           } = status_wire

    # An empty test home still composes the full native catalog: packages
    # live in the engine checkout, the home is only the destination.
    assert is_list(packages) and packages != []
    assert Enum.all?(packages, &is_map_key(&1, "id"))
    assert is_list(graph_order) and graph_order != []

    {diff_result, diff_output} = capture_main(["json", "diff", "--home", home])
    assert diff_result == :ok

    diff_wire = Jason.decode!(diff_output)

    assert %{"schema" => "workstation.diff.v1", "generation" => generation, "backend_diff" => records} =
             diff_wire

    assert is_binary(generation) and byte_size(generation) == 64

    # The plan of the full catalog records one changeset per entry against
    # the empty destination.
    assert is_list(records) and records != []
  end

  # --headless is the ONLY way a non-interactive caller reaches the plain
  # runner; on this pipe the gate passing is proven by the plain runner's
  # stdout ("Apply to ...") appearing at all, with the run NOT exiting 1.
  # MUTATING RUN: everything anchors on the sandbox home — the setup pins
  # WORKSTATION_HOME to it and the daemon serves that home, so the plan,
  # the apply, and the journal all live in the sandbox (the 2026-10-05
  # 17:37 real-host write incident stays structurally impossible).
  test "--headless bypasses the gate and reaches the plain runner", %{home: home} do
    original = System.get_env("TERM")

    try do
      System.put_env("TERM", "xterm-256color")

      {result, stdout} = capture_main(["apply", "--headless", "--home", home])

      assert stdout =~ "Apply to "
      refute result == {:shutdown, 1}

      # The journal belongs to the sandbox state root, never the real one.
      assert File.exists?(Path.join([home, ".local", "state", "workstation", "journal"]))
    after
      if original, do: System.put_env("TERM", original), else: System.delete_env("TERM")
    end
  end

  ## main plumbing (same contract as Workstation.CLITest's helpers)

  # The availability check is OPT-IN at daemon boot (the release boot sets
  # the env flag; a supervisor_spec test tree does not), so the live tree
  # answers the disabled "unknown" — and the status wire stays free of the
  # `update` object entirely (offline must look like no-news).
  test "update.check answers the disabled unknown and status carries no update object", %{home: home} do
    assert {:ok, %{"status" => "unknown", "reason" => "update check disabled"}} =
             DaemonClient.control("update.check", %{})

    {_result, output} = capture_main(["json", "status", "--home", home])
    wire = Jason.decode!(output)
    refute Map.has_key?(wire, "update")
  end

  # Regression (final-gate P1): a fresh home's capabilities envelope carries
  # nil-able fields — `applied_generation` (no journal yet) and a file row's
  # `mode` — and the canonical-JSON encoder crashed with "canonical JSON
  # cannot encode nil" exactly on this verb. The encoder now emits the JSON
  # `null` literal for nil, so the fresh-home read is rc 0 with the same
  # envelope shape.
  test "capabilities --json answers rc 0 on a fresh home (nil fields encode as null)", %{home: home} do
    {result, output} = capture_main(["capabilities", "--json", "--home", home])

    assert result == :ok
    wire = Jason.decode!(output)

    assert %{
             "schema" => "workstation.capabilities.v1",
             "applied_generation" => nil,
             "domains" => domains
           } = wire

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
