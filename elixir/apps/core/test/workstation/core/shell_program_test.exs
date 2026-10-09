defmodule Workstation.Core.ShellProgramTest do
  @moduledoc """
  Byte-exactness cases for the shared-shell compositor. The expected program
  bytes are literals: they are generated source state, so any drift here is a
  parity bug even when the program would still work. The functional cases run
  the generated fragments through /bin/sh and awk to prove the exit-70
  conflict contract, not just the bytes.
  """

  use ExUnit.Case, async: false

  alias Workstation.Core.ShellProgram

  @fragment_a %{"id" => "app-a", "marker" => "# workstation: app-a", "body" => "export A=1", "order" => 2}
  @fragment_b %{"id" => "app-b", "marker" => "# workstation: app-b", "body" => "export B=2", "order" => 1}

  describe "compose" do
    test "emits the exact anchored program bytes with order + sequence tie-break" do
      {program, ids} = ShellProgram.compose(".zshrc", [@fragment_a, @fragment_b], %{})

      assert ids == ["app-b", "app-a"]

      assert program == ~S"""
             #!/usr/bin/env sh
             # Managed by the workstation engine; do not edit deployed shared state by hand.
             # Owned fragments: app-b, app-a
             # Emit shell expressions literally for future shells, never evaluate at render time.
             # shellcheck disable=SC2016
             set -eu
             work="$(mktemp)"
             trap 'rm -f "$work" "$work.next"' EXIT HUP INT TERM
             cat >"$work"
             if grep -Fqx '# workstation: app-b' "$work"; then
               awk 'BEGIN { m = "# workstation: app-b"; b = "export B=2"; count = 0; bad = 0 }
             { lines[NR] = $0 }
             END {
               for (i = 1; i <= NR; i++) {
                 if (lines[i] == m) {
                   count++
                   if (i < NR && lines[i + 1] == b) { i++ } else { bad = 1 }
                 }
               }
               if (bad || count > 1) exit 70
             }
             ' "$work" || exit 70
             else
               printf '\n%s\n%s\n' '# workstation: app-b' 'export B=2' >>"$work"
             fi
             if grep -Fqx '# workstation: app-a' "$work"; then
               awk 'BEGIN { m = "# workstation: app-a"; b = "export A=1"; count = 0; bad = 0 }
             { lines[NR] = $0 }
             END {
               for (i = 1; i <= NR; i++) {
                 if (lines[i] == m) {
                   count++
                   if (i < NR && lines[i + 1] == b) { i++ } else { bad = 1 }
                 }
               }
               if (bad || count > 1) exit 70
             }
             ' "$work" || exit 70
             else
               printf '\n%s\n%s\n' '# workstation: app-a' 'export A=1' >>"$work"
             fi
             cat "$work"
             """
    end

    test "the sequence tie-break keeps equal orders in declaration order" do
      first = %{"id" => "one", "marker" => "# one", "body" => "export ONE=1", "order" => 3}
      second = %{"id" => "two", "marker" => "# two", "body" => "export TWO=2", "order" => 3}

      {_program, ids} = ShellProgram.compose(".zshrc", [first, second], %{})
      assert ids == ["one", "two"]
    end

    test "retiring fragments add their exact-block removal before the appends" do
      recorded = %{
        "retired" => %{"id" => "retired", "marker" => "# old", "body" => "export OLD=0", "order" => 1}
      }

      {program, _ids} = ShellProgram.compose(".zshrc", [@fragment_a], recorded)

      assert program =~ ~S"""
               awk 'BEGIN { m = "# old"; b = "export OLD=0"; found = 0; bad = 0 }
             { lines[NR] = $0 }
             END {
               for (i = 1; i <= NR; i++) {
                 if (lines[i] == m) {
                   if (i < NR && lines[i + 1] == b) {
                     found++; i++
                     if (out > 0 && text[out] == "") out--
                   } else { bad = 1 }
                 } else { text[++out] = lines[i] }
               }
               for (i = 1; i <= out; i++) print text[i]
               if (bad || found > 1) exit 70
             }
             ' "$work" >"$work.next" || exit 70
               mv "$work.next" "$work" || exit 70
             """

      assert program =~ "# retire fragment retired: remove its exact recorded block"
    end

    test "same-id declaration changes remove the recorded old block first" do
      recorded = %{
        "app-a" => %{"id" => "app-a", "marker" => "# workstation: app-a", "body" => "export OLD=0", "order" => 2}
      }

      {program, _ids} = ShellProgram.compose(".zshrc", [@fragment_a], recorded)

      assert program =~ "# retire fragment app-a: remove its exact recorded block"
      assert program =~ ~s(b = "export OLD=0")
      assert program =~ ~s(b = "export A=1")
    end

    test "duplicate markers owned by two fragments conflict" do
      dup = %{"id" => "dup", "marker" => "# workstation: app-a", "body" => "export DUP=1", "order" => 9}

      assert_raise ArgumentError, ~r/duplicate shell marker owned by two fragments on .zshrc/, fn ->
        ShellProgram.compose(".zshrc", [@fragment_a, dup], %{})
      end
    end

    test "composition requires at least one fragment" do
      assert_raise ArgumentError, ~r/requires at least one fragment/, fn ->
        ShellProgram.compose(".zshrc", [], %{})
      end
    end

    test "quotes and backslashes survive shell and awk quoting" do
      tricky = %{
        "id" => "tricky",
        "marker" => "# it's \"quoted\"",
        "body" => "export BACKSLASH='a\\b'",
        "order" => 1
      }

      {program, _ids} = ShellProgram.compose(".zshrc", [tricky], %{})

      # shell_quote wraps in single quotes, so double quotes survive verbatim
      # and embedded single quotes become '\'' — the Elixir string below
      # spells those bytes with doubled backslashes.
      assert program =~
               "printf '\\n%s\\n%s\\n' '# it'\\''s \"quoted\"' 'export BACKSLASH='\\''a\\b'\\''' >>\"$work\""
    end
  end

  describe "validate_target" do
    setup do
      path = Path.join(System.tmp_dir!(), "workstation-b4-shell-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(path) end)
      %{path: path}
    end

    test "missing files are adoptable", %{path: path} do
      assert ShellProgram.validate_target(path, [@fragment_a], %{}) == {:ok, nil}
    end

    test "exact installed blocks verify", %{path: path} do
      File.write!(path, "# preamble\n\n# workstation: app-a\nexport A=1\n# tail\n")
      assert ShellProgram.validate_target(path, [@fragment_a], %{}) == {:ok, nil}
    end

    test "edited, duplicated and ambiguous blocks conflict", %{path: path} do
      File.write!(path, "# workstation: app-a\nexport A=CHANGED\n")
      assert ShellProgram.validate_target(path, [@fragment_a], %{}) ==
               {:error, "edited, duplicated or ambiguous owned block for app-a (# workstation: app-a)"}

      File.write!(path, "# workstation: app-a\nexport A=1\n\n# workstation: app-a\nexport A=1\n")
      assert ShellProgram.validate_target(path, [@fragment_a], %{}) ==
               {:error, "edited, duplicated or ambiguous owned block for app-a (# workstation: app-a)"}

      File.write!(path, "# workstation: app-a\nnot-even-the-body\n")
      assert ShellProgram.validate_target(path, [@fragment_a], %{}) ==
               {:error, "edited, duplicated or ambiguous owned block for app-a (# workstation: app-a)"}
    end

    test "retiring fragments conflict only on edited old blocks", %{path: path} do
      recorded = %{"gone" => %{"id" => "gone", "marker" => "# gone", "body" => "export GONE=0", "order" => 1}}

      File.write!(path, "# gone\nexport GONE=0\n")
      assert ShellProgram.validate_target(path, [], recorded) == {:ok, nil}

      File.write!(path, "# gone\nexport GONE=TAMPERED\n")
      assert ShellProgram.validate_target(path, [], recorded) ==
               {:error,
                "edited, duplicated or ambiguous owned block to be removed for gone (# gone)"}
    end

    test "a replaced fragment still expects its recorded old body right now", %{path: path} do
      recorded = %{
        "app-a" => %{"id" => "app-a", "marker" => "# workstation: app-a", "body" => "export OLD=0", "order" => 2}
      }

      File.write!(path, "# workstation: app-a\nexport OLD=0\n")
      assert ShellProgram.validate_target(path, [@fragment_a], recorded) == {:ok, nil}

      File.write!(path, "# workstation: app-a\nexport A=1\n")

      # The removals loop (old recorded body) conflicts first: the marker is
      # present but not followed by the old body it must remove.
      assert ShellProgram.validate_target(path, [@fragment_a], recorded) ==
               {:error,
                "edited, duplicated or ambiguous owned block to be removed for app-a (# workstation: app-a)"}
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
      {program, _ids} = ShellProgram.compose(".zshrc", [@fragment_a], %{})
      run_program = fn contents, dir ->
        script = Path.join(dir, "modify.sh")
        File.write!(script, String.replace(program, "$(mktemp)", Path.join(dir, "work")))
        File.write!(Path.join(dir, "input"), contents)
        System.cmd("/bin/sh", ["-c", "/bin/sh '#{script}' < input"], cd: dir)
      end

      dir = Path.join(System.tmp_dir!(), "workstation-b4-awk-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      {out, 0} = run_program.("keep\n\n# workstation: app-a\nexport A=1\n", dir)
      assert out == "keep\n\n# workstation: app-a\nexport A=1\n"

      {_out, 70} = run_program.("# workstation: app-a\nexport A=TAMPERED\n", dir)
      {_out, 70} = run_program.("# workstation: app-a\nexport A=1\n\n# workstation: app-a\nexport A=1\n", dir)
    end
  end

  describe "recipe and spec validation" do
    test "recipe validates target and fragment and copies plain data" do
      recipe =
        ShellProgram.recipe(%{
          "target" => ".zshrc",
          "fragment" => %{"id" => "app", "marker" => "# m", "body" => "export X=1", "order" => 1}
        })

      assert recipe["provider"] == "shell"
      assert recipe["spec"]["target"] == ".zshrc"
      assert recipe["spec"]["components"] == [".zshrc"]
      assert recipe["spec"]["fragment"]["id"] == "app"
      assert ShellProgram.validate_spec(recipe["spec"]) == :ok
    end

    test "recipe rejects unknown options and bad fragments" do
      assert_raise ArgumentError, ~r/shell recipe has unknown option "extra"/, fn ->
        ShellProgram.recipe(%{"target" => ".zshrc", "fragment" => %{"id" => "a"}, "extra" => 1})
      end

      assert_raise ArgumentError, ~r/shell fragment requires a positive integer order/, fn ->
        ShellProgram.recipe(%{
          "target" => ".zshrc",
          "fragment" => %{"id" => "a", "marker" => "# m", "body" => "b", "order" => 1.5}
        })
      end

      assert_raise ArgumentError, ~r/shell fragment marker must not contain control characters or newlines/, fn ->
        ShellProgram.recipe(%{
          "target" => ".zshrc",
          "fragment" => %{"id" => "a", "marker" => "# m\n", "body" => "b", "order" => 1}
        })
      end

      assert_raise ArgumentError, ~r/shell target must not traverse/, fn ->
        ShellProgram.validate_spec(%{
          "target" => "a/../b",
          "components" => ["a", "..", "b"],
          "fragment" => %{"id" => "a", "marker" => "# m", "body" => "b", "order" => 1}
        })
      end
    end
  end
end
