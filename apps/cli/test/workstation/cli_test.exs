defmodule Workstation.CLITest do
  # Serialized (async: false) for the same one-VM-wide-fact reason as the
  # EnvContract module below — here the fact is :stderr. The suite asserts
  # on CAPTURED STDERR: the help contract's no-execution proof pins it
  # empty, and the refusal tests refute sibling phrases on it. :stderr is
  # one VM-wide named device, so concurrent capture windows interleave
  # whatever any test writes while the device is swapped (ExUnit.CaptureIO:
  # "captured output may include output from a different test") — a sibling
  # suite's refusal lines ("error: update failed at sync: ...") leaked into
  # this suite's `assert stderr == ""` (2026-10-22). Non-async modules run
  # exclusively, so a capture window can never overlap another test's
  # writes and the strict assertions stay strict.
  use ExUnit.Case, async: false

  # Fixture homes are cross-VM collision-proof (the full note lives in
  # apps/daemon/test/workstation/daemon/generation_test.exs): the boot
  # millisecond in base36 never repeats across `mix test` VM instances the
  # way the restarted `System.unique_integer/1` sequence does, and the
  # within-VM base36 tail keeps concurrent async draws (or two calls inside
  # one test) from sharing a millisecond. Any same-named leftover is swept
  # before use and the home is removed on exit.
  defp unique_home(prefix) do
    token =
      Integer.to_string(:os.system_time(:millisecond), 36) <>
        Integer.to_string(System.unique_integer([:positive]), 36)

    home = Path.join(System.tmp_dir!(), "#{prefix}-#{token}")

    File.rm_rf!(home)
    on_exit(fn -> File.rm_rf!(home) end)
    home
  end


  alias Workstation.CLI.Router

  defp repo_root do
    # mix test runs with cwd = apps/cli; the repo root is two levels up
    # (umbrella root = repo root since the elixir/ wrapper was flattened).
    Path.expand("../..", File.cwd!())
  end

  # Fixture homes are plain directories: since the launcher fused to the
  # engine, the CLI is the product front door on real homes (the TUI confirm
  # screen and the explicit --headless flag are the mutation gates), so the
  # graduation-era test-root-marker refusal no longer exists.
  defp temp_test_root do
    root = unique_home("ws-cli-test")

    home = Path.join(root, "home")
    File.mkdir_p!(home)
    {root, home}
  end

  # Runs Router.main/1 off the test process so `exit({:shutdown, code})`
  # surfaces as a value instead of killing the test.
  defp run_main(argv) do
    me = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result =
          try do
            Router.main(argv)
            :ok
          catch
            :exit, {:shutdown, code} -> {:shutdown, code}
            :exit, reason -> {:exit, reason}
          end

        send(me, {:main_result, result})
      end)

    receive do
      {:main_result, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:down, reason}
    after
      120_000 -> flunk("router main did not finish")
    end
  end

  describe "safety guards" do
    # The b8 graduation flip removed --engine/--core; a stale caller must
    # get the usage error, not a silently ignored unknown flag.
    test "the retired --engine switch is a usage error" do
      {_root, home} = temp_test_root()

      assert {:shutdown, 2} = run_main(["status", "--engine", repo_root(), "--home", home])
    end

    test "an unknown subcommand is a usage error" do
      {_root, home} = temp_test_root()

      assert {:shutdown, 2} = run_main(["bogus", "--home", home])
    end
  end

  describe "subcommand help contract" do
    # Regression (2026-10-19 aurora): `workstation bootstrap --help` ran a
    # REAL bootstrap — the deployed release silently ignored the unknown
    # flag and executed the verb. Optimus intercepts a bare-argv --help
    # only, so the Router owns the rest: the global -h/--help flag parses
    # on every subcommand and the dispatch gate prints usage and exits 0
    # before ANY verb work (no home resolution, no terminal gate).
    # `daemon` is pinned in DaemonVerbTest, where the env fixture makes the
    # never-boots refutation hermetic.

    @help_verbs [
      "status",
      "plan",
      "capabilities"
    ]

    test "every subcommand answers --help and -h with usage, exit 0, and no execution" do
      for verb <- @help_verbs, flag <- ["--help", "-h"] do
        {_root, home} = temp_test_root()

        {result, stdout, stderr} = capture_main_both([verb, flag, "--home", home])

        assert :ok = result, "expected #{verb} #{flag} to exit 0"
        assert stdout =~ "USAGE:", "expected #{verb} #{flag} to print usage"
        assert stdout =~ "workstation #{verb}", "expected #{verb}-specific usage"

        # No side effect observable: a verb that leaked past the gate
        # cannot stay silent in this environment (no daemon, no terminal) —
        # it would exit 1/2/4 with a refusal line on stderr.
        assert stderr == "", "expected #{verb} #{flag} to execute nothing"
      end
    end

    test "status --help documents the verb's own flags" do
      {_root, home} = temp_test_root()

      {result, stdout, _stderr} = capture_main_both(["status", "--help", "--home", home])

      assert :ok = result
      assert stdout =~ "--home"
    end

    test "help <verb> prints that verb's usage (not the top-level help)" do
      {result, stdout, stderr} = capture_main_both(["help", "plan"])

      assert :ok = result
      assert stdout =~ "USAGE:"
      assert stdout =~ "workstation plan"
      assert stderr == ""
    end
  end

  # The live-read slices of this suite (canonical-json wire shape, status
  # live evaluation) live in Workstation.CLI.LiveTest: live verbs route
  # through the daemon, and those tests need a serialized in-process daemon
  # tree. The recorded-envelope replay slices retired with the goldens
  # they replayed; what stays here is the renderer's synthetic-wire contract.
  describe "plan wire text rendering" do
    test "plan text renders the declared counts, the fragment lane and the target column" do
      generation = String.duplicate("a", 64)

      wire = %{
        "schema" => "workstation.plan.v2",
        "generation" => generation,
        "declared" => %{
          "fileTargets" => [".config/rc"],
          "claimTargets" => [],
          "retire" => [".config/old"],
          "fragmentOrder" => [%{"target" => ".zshrc", "fragments" => ["a"]}]
        },
        "target_states" => %{".config/rc" => "absent", ".config/old" => "absent"}
      }

      text = Workstation.CLI.Render.core_plan(wire)

      assert text =~ ~r/^workstation plan \(core\)$/m
      assert text =~ "  generation : #{generation}"
      assert text =~ "  declared   : 1 file targets · 0 tree claims"
      assert text =~ "  fragments  : 1 on 1 rc targets"
      assert text =~ "  retire     : 1 (.config/old)"
      # The anchor's %-45s padded target column.
      assert text =~ ~r/^  target \.config\/rc +absent$/m
      assert text =~ "plan complete."
    end
  end

  # Both streams at once: the help contract's no-execution proof reads
  # stderr (a verb that leaked past the help gate would refuse loudly
  # there) while the usage text must be on stdout.
  defp capture_main_both(argv) do
    me = self()

    {pid, ref} =
      spawn_monitor(fn ->
        stderr =
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            stdout =
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

            send(me, {:main_stdout, stdout})
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

    stdout =
      receive do
        {:main_stdout, stdout} -> stdout
      after
        5_000 -> ""
      end

    stderr =
      receive do
        {:main_stderr, stderr} -> stderr
      after
        5_000 -> ""
      end

    {result, stdout, stderr}
  end
end

defmodule Workstation.CLITest.EnvContract do
  @moduledoc """
  The environment-sensitive slices of the CLI contract: home resolution
  ($WORKSTATION_HOME / $HOME) and the TERM half of the TUI-default gate.
  Serialized (`async: false`) because System env is one VM-wide fact and the
  async sibling suite must not observe a mutated environment.

  Home resolution is a pure Router precedence (flag > $WORKSTATION_HOME >
  $HOME); the wire-level pins that used to ride the retired `--input`
  replay path now live in `Workstation.CLI.LiveTest` against the real
  daemon route. This module keeps the env-only slice: no resolvable home
  is a usage error before any daemon contact.
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

  defp temp_test_root do
    root = unique_home("ws-cli-test")
    home = Path.join(root, "home")
    File.mkdir_p!(home)
    {root, home}
  end

  # One env var overridden for the duration of fun, restored after.
  defp with_env(key, value, fun) do
    original = System.get_env(key)
    if value, do: System.put_env(key, value), else: System.delete_env(key)

    try do
      fun.()
    after
      if original, do: System.put_env(key, original), else: System.delete_env(key)
    end
  end

  describe "home resolution" do
    # The Router's pure resolution precedence — the flag beats
    # $WORKSTATION_HOME, which beats $HOME. (The launcher shim rebases flag
    # and env to one destination; the retired --input replay used to carry
    # these pins through the wire.) resolve_home/1 reads a parse result's
    # options map, so a literal shape is enough here.
    test "the --home flag wins over $WORKSTATION_HOME" do
      {_r1, home} = temp_test_root()
      {_r2, env_home} = temp_test_root()

      output =
        with_env("WORKSTATION_HOME", env_home, fn ->
          Router.resolve_home(%{options: %{home: home}})
        end)

      assert output == Path.expand(home)
    end

    test "$WORKSTATION_HOME wins over $HOME" do
      {_root, env_home} = temp_test_root()
      real_home = System.get_env("HOME") || raise("HOME must be set in the test environment")

      output =
        with_env("WORKSTATION_HOME", env_home, fn ->
          Router.resolve_home(%{options: %{home: nil}})
        end)

      assert output == Path.expand(env_home)
      refute output == Path.expand(real_home)
    end

    # No resolvable home is a usage error BEFORE any daemon contact — the
    # resolution precedence has nothing to resolve, so the verb refuses at
    # the Router (exit 2, "pass --home DIR").
    test "no resolvable home is a usage error" do
      home_override = System.get_env("WORKSTATION_HOME")
      home_original = System.get_env("HOME")
      System.delete_env("WORKSTATION_HOME")
      System.delete_env("HOME")

      try do
        assert {:shutdown, 2} =
                 (fn ->
                    me = self()

                    {pid, ref} =
                      spawn_monitor(fn ->
                        result =
                          try do
                            Router.main(["status"])
                            :ok
                          catch
                            :exit, {:shutdown, code} -> {:shutdown, code}
                          end

                        send(me, {:main_result, result})
                      end)

                    receive do
                      {:main_result, result} -> result
                      {:DOWN, ^ref, :process, ^pid, reason} -> {:down, reason}
                    after
                      120_000 -> flunk("router main did not finish")
                    end
                  end).()
      after
        if home_override, do: System.put_env("WORKSTATION_HOME", home_override), else: :ok
        if home_original, do: System.put_env("HOME", home_original), else: :ok
      end
    end
  end

  describe "TUI gate environment sensitivity" do
    # ExUnit stdio is always piped, so usable_terminal?/0 must be false under
    # every TERM here; the TERM half of the conjunction is what these pin.
    test "usable_terminal? mirrors the TERM heuristic" do
      original = System.get_env("TERM")

      try do
        System.put_env("TERM", "xterm-256color")
        refute Router.usable_terminal?()

        System.put_env("TERM", "dumb")
        refute Router.usable_terminal?()

        System.delete_env("TERM")
        refute Router.usable_terminal?()
      after
        if original, do: System.put_env("TERM", original), else: System.delete_env("TERM")
      end
    end

    # The --headless bypass pin moved to Workstation.CLI.LiveTest: the
    # headless chain now needs a daemon pinned to the sandbox home (engine
    # work, M1), which cannot share this module's env bracketing.
  end
end
