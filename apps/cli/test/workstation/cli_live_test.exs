defmodule Workstation.CLI.LiveTest do
  @moduledoc """
  The live-read and headless verbs against a REAL in-process daemon tree —
  the client/daemon split's end-to-end contract for the verbs that have no
  offline form.

  Migrated from `Workstation.CLITest` (engine work, M1): live reads route
  through `status.run` / `plan.run` / `diff.run` and the headless apply
  chain drives `apply.plan` (the daemon's own mutation-bound composition)
  + `apply.run` over the socket, so these tests
  need a daemon pinned to the sandbox home and must never run concurrent
  with the async suite (WORKSTATION_HOME and the daemon tree are
  process-global). Assertions are carried over verbatim from the
  in-process era; only the transport changed.
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


  alias Workstation.CLI.{DaemonClient, Plain, Router}
  alias Workstation.Daemon.{ApplyOrchestrator, Listener}

  setup do
    home = unique_home("ws-cli-live")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    # The supervisor-spec tree never opts in to the update check, but a real
    # `Boot.run` (the ensure-daemon verb tests) leaves the node-global app
    # env enabled — pin it off here so the disabled-unknown contract is
    # order-independent (the enabled path walks the live checkout for git).
    previous_check = Application.get_env(:daemon, :update_check)
    Application.put_env(:daemon, :update_check, false)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")

      if previous_check == nil, do: Application.delete_env(:daemon, :update_check), else: Application.put_env(:daemon, :update_check, previous_check)
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
  # runner. MUTATING-RUN safety: everything anchors on the sandbox home —
  # the setup pins WORKSTATION_HOME to it and the daemon serves that home.
  # The verb's pre-replace stop DRAINS the live in-process daemon gracefully
  # (the self-stop's HALT is hooked — a supervisor-spec test tree must not
  # halt the mix run; without the hook the daemon's System.halt(0) killed
  # this suite mid-run and it passed vacuously: exit 0, no summary). The
  # verb then fails closed: the fresh daemon can only be spawned from an
  # INSTALLED RELEASE, and the mix test env has none — the honest shape of
  # the production contract here (in production the same ensure-spawn boots
  # the fresh daemon from the release and the run proceeds).
  test "headless apply stops a live daemon gracefully, then fails closed without an installed release",
       %{home: home} do
    original = System.get_env("TERM")
    socket_path = Listener.socket_path(home)
    stopped = :atomics.new(1, signed: false)

    # The graceful sequence runs for real (drain + socket removal); the hook
    # replaces only the HALT (the tree stays under ExUnit's management, like
    # the shutdown tests' hooks). "The daemon is alive" means "the stop hook
    # has not fired yet" — the in-process daemon's OS pid IS this test VM, so
    # the real kill -0 probe would rightly refuse to claim a beam death that
    # cannot happen here.
    Elixir.Application.put_env(:daemon, :shutdown_hook, fn _delay_ms, _reason ->
      :atomics.put(stopped, 1, 1)
    end)

    Elixir.Application.put_env(:cli, :beam_alive, fn _pid -> :atomics.get(stopped, 1) == 0 end)

    try do
      System.put_env("TERM", "xterm-256color")

      {result, stderr} =
        run_main_capturing_streams(["apply", "--headless", "--home", home])

      assert {:shutdown, 4} = result
      assert stderr =~ "no release binary"

      # The graceful stop ran: drain, socket node removed, hook fired in
      # place of the halt — and the verb never reached the plain runner.
      assert :atomics.get(stopped, 1) == 1
      refute File.exists?(socket_path)
    after
      Elixir.Application.delete_env(:daemon, :shutdown_hook)
      Elixir.Application.delete_env(:cli, :beam_alive)

      if original, do: System.put_env("TERM", original), else: System.delete_env("TERM")

      _ = Workstation.Daemon.Shutdown.reset()
    end
  end

  # The public headless apply chain — the plain runner over the PRODUCTION
  # executor (the same chain Router drives after its release gate) — confirms
  # the daemon's OWN composition: the confirmation wire is `apply.plan` (the
  # apply-mode composition the mutation executes), so on this first-
  # convergence home (the live catalog declares the tmux2k removal and the
  # target is on disk) the staleness guard passes and the run refuses on
  # MERIT (the unowned removal target) — never on the stale-plan false
  # positive. The old confirmation source (`plan.run`'s read-mode generation)
  # is what false-positived; driving the chain with it is refused as stale —
  # the divergence this fix removes, pinned on its old shape.
  test "the headless apply chain confirms the daemon's own composition", %{home: home} do
    target = ".config/tmux/themes/tmux2k.conf"
    path = Path.join(home, target)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "old theme\n")

    assert {:ok, %{"schema" => "workstation.plan.v1", "generation" => generation} = apply_wire} =
             DaemonClient.call("apply.plan", %{}, home: home, timeout_ms: 60_000)

    assert {:ok, %{"generation" => read_generation}} = DaemonClient.call("plan.run", %{}, home: home, timeout_ms: 60_000)
    refute generation == read_generation

    # The fixed chain: past the guard, refused on merit downstream.
    {chain_stdout, chain_stderr} = run_apply_chain(home, apply_wire)

    assert chain_stdout =~ "Apply to #{home} (generation #{generation})"
    refute chain_stdout =~ "stale plan"
    assert chain_stderr =~ "apply failed"
    assert chain_stderr =~ "never recorded as owned"
    refute chain_stderr =~ "stale plan"

    # The old confirmation source: the same chain, read-mode wire — refused
    # as stale before any engine work.
    {_old_stdout, old_stderr} = run_apply_chain(home, read_wire_as_plan(read_generation))
    assert old_stderr =~ "stale plan"
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

  # Regression (the 2026-10-14 aurora crash): a `locked` refusal arrives
  # over the wire as a STRING-coded pair (JSON), which matched no clause in
  # the lifecycle verbs' dispatch and crashed the CLI with a CaseClauseError
  # instead of the clean exit-3 lock-contention answer. `sync` rides the
  # same clause group as `bootstrap` — the verb where aurora hit it.
  test "a locked lifecycle verb exits 3 with the owner message instead of crashing", %{home: home} do
    {:ok, token, _lock} = ApplyOrchestrator.acquire("held by the contention test")

    {result, stderr} = run_main_capturing_streams(["sync", "--home", home])

    assert {:shutdown, 3} = result
    assert stderr =~ "error: locked: apply lock held by uid="

    :ok = ApplyOrchestrator.release(token)
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

  # capture_main with both streams: the verb renders progress on stdout and
  # the failure line on stderr. The failing main must not unwind the captures,
  # so the spawn forwards each stream separately.
  defp run_main_capturing_streams(argv) do
    me = self()

    {pid, ref} =
      spawn_monitor(fn ->
        stderr =
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            {result, output} = capture_main(argv)
            send(me, {:main_result, result})
            send(me, {:main_output, output})
          end)

        send(me, {:main_stderr, stderr})
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

    _ = output

    stderr =
      receive do
        {:main_stderr, stderr} -> stderr
      after
        5_000 -> ""
      end

    {result, stderr}
  end

  # The public headless chain — `Plain.run` over the production executor —
  # with both streams captured and the chain's exit swallowed (the assertions
  # read the streams; the runner's own failure shape is the CLI exit table).
  defp run_apply_chain(destination, plan) do
    me = self()

    stderr =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        stdout =
          ExUnit.CaptureIO.capture_io(:stdio, fn ->
            try do
              Plain.run(:apply, destination: destination, plan: plan)
            catch
              :exit, {:shutdown, _code} -> :failed
            end

            send(me, {:chain_done, :ok})
          end)

        send(me, {:chain_stdout, stdout})
      end)

    assert_receive({:chain_done, :ok}, 120_000)

    stdout =
      receive do
        {:chain_stdout, stdout} -> stdout
      after
        5_000 -> ""
      end

    {stdout, stderr}
  end

  # The minimal read-mode plan wire shape the old chain confirmed from
  # (`plan.run`'s projection); only the fields the chain consumes.
  defp read_wire_as_plan(generation), do: %{"generation" => generation, "plan" => %{"entries" => []}}

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
