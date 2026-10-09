defmodule Workstation.Core.ShellContractTest do
  @moduledoc """
  The shared-shell contract platform under test: the compositor's program
  bytes (the deployed state), the platform's block verification against the
  actual file, and the envelope laws. The byte-shape and conflict cases were
  pinned by the retired string-keyed parity anchor and carry over here
  against the one composer.
  """

  use ExUnit.Case, async: true

  alias Workstation.Core.Contracts.Shell
  alias Workstation.Core.Platform

  @fragment_a %{id: "app-a", marker: "# workstation: app-a", body: "export A=1", order: 5}

  describe "compose (the one compositor)" do
    test "composes the modify program with owned-fragment header" do
      {program, ids} = Shell.compose(".zshrc", [@fragment_a], %{})

      assert ids == ["app-a"]
      assert program =~ "# Owned fragments: app-a"
      assert program =~ "# workstation: app-a"
      assert program =~ "export A=1"
    end

    test "retiring fragments add their exact-block removal before the appends" do
      recorded = %{
        "retired" => %{id: "retired", marker: "# old", body: "export OLD=0", order: 1}
      }

      {program, _ids} = Shell.compose(".zshrc", [@fragment_a], recorded)

      assert program =~ "# retire fragment retired: remove its exact recorded block"
      assert program =~ "b = \"export OLD=0\""
    end

    test "same-id declaration changes remove the recorded old block first" do
      recorded = %{
        "app-a" => %{id: "app-a", marker: "# workstation: app-a", body: "export OLD=0", order: 2}
      }

      {program, _ids} = Shell.compose(".zshrc", [@fragment_a], recorded)

      assert program =~ "# retire fragment app-a: remove its exact recorded block"
      assert program =~ "b = \"export OLD=0\""
      assert program =~ "b = \"export A=1\""
    end

    test "duplicate markers owned by two fragments conflict" do
      dup = %{id: "dup", marker: "# workstation: app-a", body: "export DUP=1", order: 9}

      assert_raise ArgumentError, ~r/duplicate shell marker owned by two fragments on .zshrc/, fn ->
        Shell.compose(".zshrc", [@fragment_a, dup], %{})
      end
    end

    test "composition requires at least one fragment" do
      assert_raise ArgumentError, ~r/requires at least one fragment/, fn ->
        Shell.compose(".zshrc", [], %{})
      end
    end

    test "quotes and backslashes survive shell and awk quoting" do
      tricky = %{id: "tricky", marker: "# it's \"quoted\"", body: "export BACKSLASH='a\\b'", order: 1}

      {program, _ids} = Shell.compose(".zshrc", [tricky], %{})

      # shell_quote wraps in single quotes, so double quotes survive verbatim
      # and embedded single quotes become '\'' — the Elixir string below
      # spells those bytes with doubled backslashes.
      assert program =~
               "printf '\\n%s\\n%s\\n' '# it'\\''s \"quoted\"' 'export BACKSLASH='\\''a\\b'\\''' >>\"$work\""
    end
  end

  # The generated programs are run for real where tooling exists: the
  # conflict contract is that edited or duplicated owned blocks exit 70 and
  # clean blocks pass, mirroring what the chezmoi modify run will do.
  describe "generated programs run under /bin/sh + awk" do
    @describetag :functional

    test "verification passes on exact blocks and exits 70 on edits and duplicates" do
      # The functional contract needs only POSIX tooling; failing loudly on a
      # stripped environment is better than silently skipping the proof.
      assert System.find_executable("awk")
      assert System.find_executable("mktemp")
      {program, _ids} = Shell.compose(".zshrc", [@fragment_a], %{})

      run_program = fn contents, dir ->
        script = Path.join(dir, "modify.sh")
        File.write!(script, String.replace(program, "$(mktemp)", Path.join(dir, "work")))
        File.write!(Path.join(dir, "input"), contents)
        System.cmd("/bin/sh", ["-c", "/bin/sh '#{script}' < input"], cd: dir)
      end

      dir = Path.join(System.tmp_dir!(), "workstation-shell-awk-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      {out, 0} = run_program.("keep\n\n# workstation: app-a\nexport A=1\n", dir)
      assert out == "keep\n\n# workstation: app-a\nexport A=1\n"

      {_out, 70} = run_program.("# workstation: app-a\nexport A=TAMPERED\n", dir)
      {_out, 70} = run_program.("# workstation: app-a\nexport A=1\n\n# workstation: app-a\nexport A=1\n", dir)
    end
  end

  describe "group (the platform grouping law)" do
    test "fragments group per target, explicit order key first, collection order as tie-break" do
      records = [
        %{owner: "b", spec: shell_spec(".zshrc", %{id: "late", marker: "# late", body: "export L=1", order: 30})},
        %{owner: "a", spec: shell_spec(".profile", %{id: "p", marker: "# p", body: "export P=1", order: 1})},
        %{owner: "a2", spec: shell_spec(".zshrc", %{id: "early", marker: "# early", body: "export E=1", order: 10})}
      ]

      grouped = Platform.Shell.group(records)
      assert Map.keys(grouped) == [".profile", ".zshrc"]

      assert Enum.map(grouped[".zshrc"].fragments, & &1.id) == ["early", "late"]
      assert grouped[".zshrc"].owners == ["b", "a2"]
    end

    test "duplicate fragment ids and duplicate markers fail closed per target" do
      dup_id = [
        %{owner: "a", spec: shell_spec(".zshrc", %{id: "x", marker: "# one", body: "export X=1", order: 1})},
        %{owner: "b", spec: shell_spec(".zshrc", %{id: "x", marker: "# two", body: "export X=2", order: 2})}
      ]

      assert_raise ArgumentError, ~r/duplicate shell fragment id on .zshrc/, fn ->
        Platform.Shell.group(dup_id)
      end

      dup_marker = [
        %{owner: "a", spec: shell_spec(".zshrc", %{id: "x", marker: "# one", body: "export X=1", order: 1})},
        %{owner: "b", spec: shell_spec(".zshrc", %{id: "y", marker: "# one", body: "export Y=1", order: 2})}
      ]

      assert_raise ArgumentError, ~r/duplicate shell marker # one on .zshrc/, fn ->
        Platform.Shell.group(dup_marker)
      end
    end

    test "journal records project the string-keyed recorded shape" do
      records = [
        %{owner: "a", spec: shell_spec(".zshrc", %{id: "x", marker: "# one", body: "export X=1", order: 7})}
      ]

      [record] = records |> Platform.Shell.group() |> Map.fetch!(".zshrc") |> Platform.Shell.journal_records()

      assert record == %{
               "id" => "x",
               "marker" => "# one",
               "body" => "export X=1",
               "order" => 7,
               "owner" => "a",
               "sequence" => 1
             }
    end
  end

  describe "recipe and spec validation" do
    test "recipe validates target and fragment and derives components" do
      recipe =
        Shell.recipe(%{
          target: ".zshrc",
          fragment: %{id: "app", marker: "# m", body: "export X=1", order: 1}
        })

      assert recipe.target == ".zshrc"
      assert recipe.components == [".zshrc"]
      assert recipe.fragment.id == "app"
      assert Shell.validate_spec(recipe) == :ok
    end

    test "recipe rejects unknown options and bad fragments" do
      assert_raise ArgumentError, ~r/shell recipe has unknown option :extra/, fn ->
        Shell.recipe(%{target: ".zshrc", fragment: %{id: "a"}, extra: 1})
      end

      assert_raise ArgumentError, ~r/shell fragment requires a positive integer order/, fn ->
        Shell.recipe(%{target: ".zshrc", fragment: %{id: "a", marker: "# m", body: "b", order: 1.5}})
      end

      assert_raise ArgumentError, ~r/shell fragment marker must not contain control characters or newlines/, fn ->
        Shell.recipe(%{target: ".zshrc", fragment: %{id: "a", marker: "# m\n", body: "b", order: 1}})
      end

      assert_raise ArgumentError, ~r/shell target must not traverse/, fn ->
        Shell.validate_spec(%Shell{
          target: "a/../b",
          components: ["a", "..", "b"],
          fragment: %{id: "a", marker: "# m", body: "b", order: 1}
        })
      end
    end
  end

  defp shell_spec(target, fragment), do: Shell.recipe(%{target: target, fragment: fragment})
end
