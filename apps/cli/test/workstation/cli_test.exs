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
      "diff",
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
      assert stdout =~ "--input"
    end

    test "help <verb> prints that verb's usage (not the top-level help)" do
      {result, stdout, stderr} = capture_main_both(["help", "plan"])

      assert :ok = result
      assert stdout =~ "USAGE:"
      assert stdout =~ "workstation plan"
      assert stderr == ""
    end
  end

  # The live-read slices of this suite (canonical-json wire shape, status/diff
  # live-catalog evaluation) moved to Workstation.CLI.LiveTest: live verbs
  # route through the daemon now, and those tests need a serialized in-process
  # daemon tree (engine work, M1). Only the --input offline-replay slices
  # stay here.
  describe "core evaluation (graduated default)" do
    defp golden_dir(profile), do: Path.join([repo_root(), "tests", "goldens", profile])

    defp core_argv(commands, home, extra) do
      String.split(commands, " ") ++ ["--home", home] ++ extra
    end

    test "plan --input reproduces the recorded golden envelope (offline byte parity)" do
      golden = golden_dir("minimal")
      {_root, home} = temp_test_root()

      argv = core_argv("json plan", home, ["--input", Path.join([golden, "input.json"])])

      {result, first} = capture_main(argv)
      assert result == :ok

      {_result, second} = capture_main(argv)
      # Identical evaluation state yields byte-identical wire bytes.
      assert first == second

      wire = Jason.decode!(first)

      assert %{
               "schema" => "workstation.plan.v1",
               "generation" => generation,
               "plan" => _plan,
               "manifest" => _manifest,
               "patches" => patches,
               "target_states" => states
             } = wire

      # Envelope-level golden equality (the supervisor-approved contract):
      # the plan body and manifest are the recorded content-addressed
      # artifacts verbatim, so the comparison is over canonical bytes of the
      # sub-documents, never over decoded shapes, where an empty map and an
      # empty list are the same recorded bytes.
      assert canonical_json(wire["plan"]) == File.read!(Path.join([golden, "expected", "plan.json"]))

      assert canonical_json(wire["manifest"]) ==
               File.read!(Path.join([golden, "expected", "manifest.json"]))

      assert generation == String.trim_trailing(File.read!(Path.join([golden, "expected", "generation.txt"])))

      assert is_list(patches)
      assert is_map(states)
      # The CLI wire is itself canonical JSON (compact, keys sorted).
      assert String.trim_trailing(first, "\n") == canonical_json(wire)
    end

    test "status --input derives identity from the replayed envelope" do
      golden = golden_dir("minimal")
      {_root, home} = temp_test_root()

      {result, output} =
        capture_main(core_argv("json status", home, ["--input", Path.join([golden, "input.json"])]))

      assert result == :ok
      wire = Jason.decode!(output)

      assert %{
               "schema" => "workstation.status.v1",
               "engine" => %{"name" => "workstation", "mode" => "elixir"},
               "destination" => destination,
               "packages" => packages,
               "graph_order" => graph_order,
               "journal" => nil
             } = wire

      assert destination == Path.expand(home)
      assert is_list(packages) and packages != []
      assert Enum.all?(packages, &is_map_key(&1, "id"))
      assert is_list(graph_order)
      # A fresh test home has no applied generation.
    end

    test "plan text mirrors the changesets.print_report layout" do
      generation = String.duplicate("a", 64)

      wire = %{
        "schema" => "workstation.plan.v1",
        "generation" => generation,
        "plan" => %{
          "profile" => "minimal",
          "host" => "linux",
          "journal_revision" => 0,
          "baseline_generation" => nil,
          "entries" => [
            %{
              "name" => "bashrc",
              "target" => ".bashrc",
              "operation" => "add",
              "type" => "file",
              "mode" => "0755",
              "attribution" => ["foundation"],
              "bytes_sha256" => "abc",
              "fingerprint" => "fp1"
            }
          ],
          "removals" => [],
          "unsupported_reversals" => []
        },
        "manifest" => [],
        "patches" => [
          %{
            "kind" => "add",
            "source" => "bashrc",
            "owner" => "foundation",
            "attribution" => ["foundation"],
            "target" => ".bashrc",
            "type" => "file",
            "mode" => "755"
          }
        ],
        "target_states" => %{".bashrc" => "absent"}
      }

      text = Workstation.CLI.Render.core_plan(wire)

      assert text =~ ~r/^workstation plan \(core\)$/m
      assert text =~ "  generation : #{generation}"
      assert text =~ "  entries    : 1  removals: 0"
      assert text =~ "  baseline   : none (initial plan; every source entry is an addition)"
      assert text =~ "  add bashrc -> .bashrc [file mode 755] owner foundation"
      assert text =~ "# add bashrc (file mode 755, owner foundation)"
      # The anchor's %-45s padded target column.
      assert text =~ ~r/^  target \.bashrc +absent$/m
      assert text =~ "plan complete."
    end

    test "a core evaluation conflict or precondition exits 3" do
      {_root, home} = temp_test_root()
      envelope = unique_home("ws-core-input") <> ".json"

      File.write!(envelope, ~s({"profile": "exit3", "host": "linux", "home": "/home/golden",
        "packages": [{"id": "a", "requires": ["ghost"], "contributes": []}], "assets": {}}))

      assert {:shutdown, 3} = run_main(core_argv("plan", home, ["--input", envelope]))
    end
  end

  # Like capture_main but captures stderr (not stdout): the contract refusals
  # print on stderr, and the plain runner prints progress on stdout — this
  # helper is for the refusal shape, where the message is what matters.
  defp capture_main_with_stderr(argv) do
    me = self()

    {pid, ref} =
      spawn_monitor(fn ->
        output =
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
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

  # Minimal canonical JSON mirror: compact separators,
  # object keys sorted ascending bytewise, arrays in order.
  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map(fn {key, inner} -> Jason.encode!(key) <> ":" <> canonical_json(inner) end)

    "{" <> Enum.join(entries, ",") <> "}"
  end

  defp canonical_json(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"
  end

  defp canonical_json(value), do: Jason.encode!(value)
end

defmodule Workstation.CLITest.EnvContract do
  @moduledoc """
  The environment-sensitive slices of the CLI contract: home resolution
  ($WORKSTATION_HOME / $HOME) and the TERM half of the TUI-default gate.
  Serialized (`async: false`) because System env is one VM-wide fact and the
  async sibling suite must not observe a mutated environment.

  The home-resolution pins ride the `--input` offline-replay path (engine
  work, M1): live reads are daemon-routed now, and the daemon pins its own
  home — so the RESOLUTION precedence this suite pins is exercised where it
  actually lives, in the Router's flag > $WORKSTATION_HOME > $HOME chain,
  against an envelope that deliberately names a different home.
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

  # Runs Router.main/1 off the test process with one env var overridden for
  # the run; the spawned process inherits the mutated environment at spawn.
  # Returns {result, stdout, stderr}: json output rides stdout, contract
  # refusals ride stderr.
  defp run_main_with_env(argv, key, value) do
    original = System.get_env(key)
    if value, do: System.put_env(key, value), else: System.delete_env(key)

    try do
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
    after
      if original, do: System.put_env(key, original), else: System.delete_env(key)
    end
  end

  describe "home resolution" do
    # The flag beats $WORKSTATION_HOME, which beats $HOME — the launcher shim
    # rebases both to one destination, so verbs address the intended home.
    # --input keeps these offline (envelope home is a red herring on
    # purpose): the wire's destination must be the RESOLVED home, never the
    # ambient environment and never the recorded envelope's home.
    test "--home wins over $WORKSTATION_HOME" do
      {_r1, home} = temp_test_root()
      {_r2, env_home} = temp_test_root()
      envelope = offline_envelope()

      {:ok, output, _stderr} =
        run_main_with_env(["json", "status", "--home", home, "--input", envelope], "WORKSTATION_HOME", env_home)

      assert Jason.decode!(output)["destination"] == Path.expand(home)
    end

    test "$WORKSTATION_HOME wins over $HOME" do
      {_root, env_home} = temp_test_root()
      real_home = System.get_env("HOME") || raise("HOME must be set in the test environment")
      envelope = offline_envelope()

      {:ok, output, _stderr} =
        run_main_with_env(["json", "status", "--input", envelope], "WORKSTATION_HOME", env_home)

      wire = Jason.decode!(output)
      assert wire["destination"] == Path.expand(env_home)
      refute wire["destination"] == real_home
    end

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

  # A minimal valid catalog envelope whose recorded home is deliberately
  # NOT any sandbox home: resolution precedence must send the wire's
  # destination to the resolved home, never the envelope's.
  defp offline_envelope do
    path = unique_home("ws-env-envelope") <> ".json"

    File.write!(path, ~s({"profile": "env-resolution", "host": "linux", "home": "/home/golden",
      "packages": [], "assets": {}}))

    path
  end
end
