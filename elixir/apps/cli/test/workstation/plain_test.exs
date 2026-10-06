defmodule Workstation.CLITest.PlainTest do
  @moduledoc """
  The plain runner's release handoff: a refreshed bootstrap halts the
  daemon-side chain and the op result reports `handed_off` plus the steps
  that did not run — the remaining steps must execute under the NEW
  release (the `--resume-from` child), never with the stale code the
  original process loaded at boot — the live `workstation update` crashed
  on exactly this gap when a mid-run release refresh left the chain
  running old code.
  """

  use ExUnit.Case, async: false

  alias Workstation.CLI.Plain

  setup do
    root = Path.join(System.tmp_dir!(), "ws-cli-plain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "a daemon-reported handoff re-runs the remaining steps under the new release", %{root: root} do
    release = fake_release(root, 0)

    # The daemon OWNS the decision now: one update.run op carries the whole
    # chain, and the result reports handed_off plus the steps that did NOT
    # run (a refreshed bootstrap halts the daemon-side chain before the
    # next step). The runner only renders and re-execs.
    {:ok, exec_pid} = Agent.start_link(fn -> nil end)

    executor = fn %{"steps" => steps, "events" => events} ->
      Agent.update(exec_pid, fn _ -> steps end)

      Enum.each(Enum.take(steps, 3), fn step ->
        events.(%{"type" => "step.done", "step" => step, "ok" => true, "detail" => nil})
      end)

      {:ok, %{"handed_off" => true, "remaining_steps" => ["sync", "verify"]}}
    end

    output =
      ExUnit.CaptureIO.capture_io(:stdio, fn ->
        assert :ok =
                 Plain.run(:update, destination: "HOME",
                   executor: executor, handoff_release_root: release
                 )
      end)

    # The executor saw the WHOLE chain as one op — there is no per-step
    # client drive anymore.
    assert Agent.get(exec_pid, & &1) == ["pull", "bootstrap", "apply", "sync", "verify"]

    # The remaining steps are reported as handed off with their original
    # chain numbering, and the child receives the resume contract.
    assert output =~ "[3/5] apply ok"
    assert output =~ "[4/5] sync handed off to the refreshed release"
    assert output =~ "[5/5] verify handed off to the refreshed release"
    assert output =~ "Update handed off to #{release}"

    assert File.read!(Path.join(root, "child.argv")) |> String.trim_trailing("\n") ==
             "update --headless --resume-from sync,verify"

    # The final banner comes from the child (the new release completing the
    # chain), not from the stale parent.
    assert output =~ "Updated"
    assert output |> String.split("Updated") |> length() == 2
  end

  test "a handoff child spawned through its launcher binary sees the bracketed environment", %{root: root} do
    # The live 2026-10-05 handoff ran through the real launcher shim, which
    # re-exports HOME/WORKSTATION_HOME/XDG_* before exec — this test spawns
    # the child the same way the runner does (a real bin/workstation exec,
    # not an in-process Router call) and pins the environment contract: the
    # child must inherit the parent's WORKSTATION_HOME bracket so it
    # re-derives the same engine state (and handoff note path).
    previous_ws = System.get_env("WORKSTATION_HOME")
    previous_home = System.get_env("HOME")

    System.put_env("WORKSTATION_HOME", root)
    System.put_env("HOME", root)

    on_exit(fn ->
      restore_env("WORKSTATION_HOME", previous_ws)
      restore_env("HOME", previous_home)
    end)

    release = fake_release(root, 0)

    output =
      ExUnit.CaptureIO.capture_io(:stdio, fn ->
        assert :ok =
                 Plain.run(:update, destination: "HOME",
                   executor: fn %{"steps" => _s, "events" => _e} ->
                     {:ok, %{"handed_off" => true, "remaining_steps" => ["bootstrap", "apply", "sync", "verify"]}}
                   end,
                   handoff_release_root: release
                 )
      end)

    # The child argv is the resume contract; the child env is the state
    # contract (it re-derives the handoff note path from WORKSTATION_HOME).
    assert File.read!(Path.join(root, "child.argv")) |> String.trim_trailing("\n") ==
             "update --headless --resume-from bootstrap,apply,sync,verify"

    assert File.read!(Path.join(root, "child.env")) == "#{root}\n"
    assert output =~ "Updated"
  end

  test "parent success clears the handoff note (consumed exactly once)", %{root: root} do
    release = fake_release(root, 0)

    previous_ws = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", root)
    on_exit(fn -> restore_env("WORKSTATION_HOME", previous_ws) end)

    note = note_path(root)
    File.mkdir_p!(Path.dirname(note))
    File.write!(note, Jason.encode!(%{"from_release" => "stale"}))

    {:ok, clear_pid} = Agent.start_link(fn -> 0 end)

    ExUnit.CaptureIO.capture_io(:stdio, fn ->
      assert :ok =
               Plain.run(:update, destination: "HOME",
                 executor: fn %{"steps" => _s, "events" => _e} ->
                   {:ok, %{"handed_off" => true, "remaining_steps" => ["sync", "verify"]}}
                 end,
                 handoff_release_root: release,
                 handoff_clear: fn _opts -> Agent.update(clear_pid, &(&1 + 1)) end
               )
    end)

    # Parent success = child exit 0 + note consumed exactly once: the
    # cleared note can never re-derive a handoff that already finished.
    assert Agent.get(clear_pid, & &1) == 1
  end

  test "a failed handed-off child leaves the note for re-derivation", %{root: root} do
    release = fake_release(root, 3)

    previous_ws = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", root)
    on_exit(fn -> restore_env("WORKSTATION_HOME", previous_ws) end)

    note = note_path(root)
    File.mkdir_p!(Path.dirname(note))
    File.write!(note, Jason.encode!(%{"from_release" => "stale"}))

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      assert catch_exit(
               ExUnit.CaptureIO.capture_io(:stdio, fn ->
                 Plain.run(:update, destination: "HOME",
                   executor: fn %{"steps" => _s, "events" => _e} ->
                     {:ok, %{"handed_off" => true, "remaining_steps" => ["sync", "verify"]}}
                   end,
                   handoff_release_root: release
                 )
               end)
             ) == {:shutdown, 4}
    end)

    # A crashed re-exec must leave the note: the next update run re-derives
    # the same handoff instead of finishing the chain under stale code.
    assert File.exists?(note)
  end

  test "an empty remaining handoff never spawns a child", %{root: root} do
    # The live incident's exit-2 trigger: an empty --resume-from child.
    # The daemon reports handed_off with nothing left only in a degenerate
    # case, but the client-side guard must hold regardless: nothing left to
    # hand off = finish normally — proven here by a release root with no
    # bin/workstation at all (a spawn would fail loudly).
    release = Path.join(root, "never-spawned")

    output =
      ExUnit.CaptureIO.capture_io(:stdio, fn ->
        assert :ok =
                 Plain.run(:update, destination: "HOME",
                   executor: fn %{"steps" => _s, "events" => _e} ->
                     {:ok, %{"handed_off" => true, "remaining_steps" => []}}
                   end,
                   handoff_release_root: release
                 )
      end)

    refute output =~ "handed off"
    assert output =~ "Updated"
  end

  test "a validation exit under the handed-off release fails fast, exactly once", %{root: root} do
    release = fake_release(root, 2)

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert catch_exit(
                 ExUnit.CaptureIO.capture_io(:stdio, fn ->
                   Plain.run(:update, destination: "HOME",
                     executor: fn %{"steps" => _s, "events" => _e} ->
                       {:ok, %{"handed_off" => true, "remaining_steps" => ["sync", "verify"]}}
                     end,
                     handoff_release_root: release
                   )
                 end)
               ) == {:shutdown, 4}
      end)

    # The live incident retried a validation failure three generations
    # deep; the parent must echo the child's status and stop — one spawn,
    # one failure, no retry loop.
    assert output =~ "update failed under the handed-off release (exit 2)"
    assert length(String.split(File.read!(Path.join(root, "child.argv")), "\n", trim: true)) == 1
  end

  test "a nonzero child exit fails the run with the child's status", %{root: root} do
    release = fake_release(root, 3)

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert catch_exit(
                 ExUnit.CaptureIO.capture_io(:stdio, fn ->
                   Plain.run(:update, destination: "HOME",
                     executor: fn %{"steps" => _s, "events" => _e} ->
                       {:ok, %{"handed_off" => true, "remaining_steps" => ["sync", "verify"]}}
                     end,
                     handoff_release_root: release
                   )
                 end)
               ) == {:shutdown, 4}
      end)

    assert output =~ "update failed under the handed-off release (exit 3)"
  end

  test "the composition spawns the daemon-REPORTED release ROOT, never the note's identity value", %{root: root} do
    # The P0 in 0fb69a4f shipped because the unit tests injected a
    # PATH-SHAPED probe value while production passed the identity stamp:
    # the note and the spawn must meet through the real daemon report, and
    # the spawn bin must be derived from the reported release ROOT — a
    # stamp-shaped note value used as a spawn path raised a raw :enoent
    # ErlangError on the live host. This test composes the REAL result
    # shape (the daemon merges release_root into the handoff record) with
    # the real spawn-path derivation and a STAMP-shaped note value.
    release = fake_release(root, 0)
    previous_ws = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", root)
    on_exit(fn -> restore_env("WORKSTATION_HOME", previous_ws) end)

    # The note names the WRITER identity (what a pre-install capture
    # records), NOT a location — the old bug treated the identity as the
    # child bin. The client must never read it for spawning.
    note = note_path(root)
    File.mkdir_p!(Path.dirname(note))
    File.write!(note, Jason.encode!(%{"from_release" => "pre-refresh-stamp"}))

    output =
      ExUnit.CaptureIO.capture_io(:stdio, fn ->
        assert :ok =
                 Plain.run(:update, destination: "HOME",
                   executor: fn %{"steps" => _s, "events" => _e} ->
                     {:ok,
                      %{
                        "handed_off" => true,
                        "remaining_steps" => ["bootstrap", "apply", "sync", "verify"],
                        "release_root" => release
                      }}
                   end
                 )
      end)

    # The daemon-reported release root drove the spawn; the child ran the
    # remaining chain.
    assert output =~ "[2/5] bootstrap handed off to the refreshed release"
    assert output =~ "Update handed off to #{release}"

    assert File.read!(Path.join(root, "child.argv")) |> String.trim_trailing("\n") ==
             "update --headless --resume-from bootstrap,apply,sync,verify"

    # The spawned BIN is the reported release root's launcher — recorded by
    # the child itself as $0 — never the identity token.
    assert File.read!(Path.join(root, "child.bin")) |> String.trim_trailing("\n") ==
             Path.join([release, "bin", "workstation"])

    # Parent success = child exit 0 + note consumed (default clear against
    # the bracketed WORKSTATION_HOME).
    refute File.exists?(note)
  end

  test "a handed-off release without an executable bin fails cleanly, note intact", %{root: root} do
    # The live P0 surfaced as a raw :enoent ErlangError (exit 1, note
    # stranded): the launcher-shape guard must turn a missing or
    # non-executable bin into the controlled engine failure (exit 4)
    # before any spawn.
    release = Path.join([root, "empty-release"])
    File.mkdir_p!(Path.join([release, "bin"]))

    previous_ws = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", root)
    on_exit(fn -> restore_env("WORKSTATION_HOME", previous_ws) end)

    note = note_path(root)
    File.mkdir_p!(Path.dirname(note))
    File.write!(note, Jason.encode!(%{"from_release" => "stale"}))

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert catch_exit(
                 ExUnit.CaptureIO.capture_io(:stdio, fn ->
                   Plain.run(:update, destination: "HOME",
                     executor: fn %{"steps" => _s, "events" => _e} ->
                       {:ok,
                        %{"handed_off" => true, "remaining_steps" => ["sync", "verify"], "release_root" => release}}
                     end
                   )
                 end)
               ) == {:shutdown, 4}
      end)

    assert output =~ "no executable workstation binary at #{Path.join([release, "bin", "workstation"])}"

    # The failure precedes the spawn: the note survives for re-derivation.
    assert File.exists?(note)
  end

  test "an invalid --resume-from list is a usage error, never a chain run" do
    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert catch_exit(
                 Plain.run(:update,
                   destination: "HOME",
                   executor: fn _payload -> flunk("the executor must not run for an invalid resume list") end,
                   resume_from: "nope"
                 )
               ) == {:shutdown, 2}
      end)

    assert output =~ "unknown update step"
  end

  test "a duplicated --resume-from step is a usage error" do
    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert catch_exit(
                 Plain.run(:update,
                   destination: "HOME",
                   executor: fn _payload -> flunk("the executor must not run for an invalid resume list") end,
                   resume_from: "apply,apply"
                 )
               ) == {:shutdown, 2}
      end)

    assert output =~ "lists a step twice"
  end

  test "an empty --resume-from list is a usage error" do
    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert catch_exit(
                 Plain.run(:update,
                   destination: "HOME",
                   executor: fn _payload -> flunk("the executor must not run for an invalid resume list") end,
                   resume_from: ","
                 )
               ) == {:shutdown, 2}
      end)

    assert output =~ "requires a comma-separated step list"
  end

  test "an aborted op fails the chain and marks the un-run steps skipped" do
    # M2 abort semantics over the wire: the daemon answers the abort at the
    # NEXT step boundary, the result arrives as the aborted error code, and
    # everything the daemon did not settle renders skipped with its
    # original chain numbering.
    stdout =
      ExUnit.CaptureIO.capture_io(:stdio, fn ->
        stderr_lines =
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            assert catch_exit(
                     Plain.run(:update, destination: "HOME",
                       executor: fn %{"steps" => _s, "events" => events} ->
                         events.(%{"type" => "step.done", "step" => "pull", "ok" => true, "detail" => nil})
                         {:error, {"aborted", "update aborted at a step boundary"}}
                       end
                     )
                   ) == {:shutdown, 4}
          end)

        send(self(), {:plain_stderr, stderr_lines})
      end)

    stderr =
      receive do
        {:plain_stderr, lines} -> lines
      after
        1_000 -> ""
      end

    output = stdout <> stderr

    assert output =~ "[1/5] pull ok"
    assert output =~ "[2/5] bootstrap skipped"
    assert output =~ "[5/5] verify skipped"
    assert output =~ "update aborted at a step boundary"
  end

  # The child stand-in: records its argv (space-joined, the resume contract
  # is what matters), its inherited WORKSTATION_HOME (the state contract —
  # the child re-derives the handoff note path from it), and exits with the
  # configured status.
  defp fake_release(root, exit_code) do
    bin = Path.join([root, "fake-release", "bin", "workstation"])
    File.mkdir_p!(Path.dirname(bin))

    File.write!(
      bin,
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> #{root}/child.argv\nprintf '%s\\n' \"$WORKSTATION_HOME\" >> #{root}/child.env\nprintf '%s\\n' \"$0\" >> #{root}/child.bin\necho Updated\nexit #{exit_code}\n"
    )

    File.chmod!(bin, 0o755)
    Path.join([root, "fake-release"])
  end

  defp note_path(root),
    do: Path.join([root, ".local", "state", "workstation", "update", "handoff.json"])

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
