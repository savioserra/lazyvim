defmodule Workstation.CLITest do
  use ExUnit.Case, async: true

  alias Workstation.CLI.Router

  @marker Router.test_root_marker()

  defp repo_root do
    Path.expand("../../..", File.cwd!())
  end

  defp temp_test_root(with_marker \\ true) do
    root =
      Path.join(System.tmp_dir!(), "ws-cli-test-#{System.unique_integer([:positive])}")

    home = Path.join(root, "home")
    File.mkdir_p!(home)

    if with_marker do
      File.touch!(Path.join(home, @marker))
    end

    on_exit(fn -> File.rm_rf!(root) end)
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
    test "missing --home is refused" do
      {_root, _home} = temp_test_root()

      assert {:shutdown, 2} = run_main(["status"])
    end

    # The b8 graduation flip removed --engine/--core; a stale caller must
    # get the usage error, not a silently ignored unknown flag.
    test "the retired --engine switch is a usage error" do
      {_root, home} = temp_test_root()

      assert {:shutdown, 2} = run_main(["status", "--engine", repo_root(), "--home", home])
    end

    test "the real $HOME is refused" do
      real_home = System.get_env("HOME") || raise("HOME must be set in the test environment")

      assert {:shutdown, 77} = run_main(["status", "--home", real_home])
    end

    test "a home without the test-root marker is refused" do
      {_root, home} = temp_test_root(false)
      refute File.exists?(Path.join(home, @marker))

      assert {:shutdown, 77} = run_main(["status", "--home", home])
    end

    test "an unknown subcommand is a usage error" do
      {_root, home} = temp_test_root()

      assert {:shutdown, 2} = run_main(["bogus", "--home", home])
    end
  end

  describe "native collection" do
    @describetag :collect

    test "json output is canonical JSON (compact, keys sorted)" do
      {_root, home} = temp_test_root()

      {result, output} = capture_main(["json", "status", "--home", home])

      assert result == :ok
      wire = Jason.decode!(output)
      assert String.trim_trailing(output, "\n") == canonical_json(wire)
    end

  end

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
      # sub-documents, never over decoded shapes where a Lua empty table
      # ([]) and an Elixir empty map could diverge.
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
      envelope = Path.join(System.tmp_dir!(), "ws-core-input-#{System.unique_integer([:positive])}.json")

      File.write!(envelope, ~s({"profile": "exit3", "host": "linux", "home": "/home/golden",
        "packages": [{"id": "a", "requires": ["ghost"], "contributes": []}], "assets": {}}))

      on_exit(fn -> File.rm(envelope) end)

      assert {:shutdown, 3} = run_main(core_argv("plan", home, ["--input", envelope]))
    end

    test "status and diff evaluate the live home through the native catalog" do
      {_root, home} = temp_test_root()

      {status_result, status_output} = capture_main(core_argv("json status", home, []))
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

      {diff_result, diff_output} = capture_main(core_argv("json diff", home, []))
      assert diff_result == :ok

      diff_wire = Jason.decode!(diff_output)

      assert %{"schema" => "workstation.diff.v1", "generation" => generation, "backend_diff" => records} =
               diff_wire

      assert is_binary(generation) and byte_size(generation) == 64

      # The plan of the full catalog records one changeset per entry against
      # the empty destination.
      assert is_list(records) and records != []
      assert Enum.all?(records, &is_map_key(&1, "operation"))
    end
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
