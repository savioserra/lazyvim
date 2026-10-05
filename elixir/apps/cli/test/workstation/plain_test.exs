defmodule Workstation.CLITest.PlainTest do
  @moduledoc """
  The plain runner's release handoff: after a refreshed bootstrap step the
  remaining update steps must execute under the NEW release (the
  `--resume-from` child), never with the stale code the original process
  loaded at boot — the live `workstation update` crashed on exactly this
  gap when a mid-run release refresh left the chain running old code.
  """

  use ExUnit.Case, async: false

  alias Workstation.CLI.Plain

  setup do
    root = Path.join(System.tmp_dir!(), "ws-cli-plain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "a handoff decision after bootstrap re-runs the remaining steps under the new release", %{root: root} do
    release = fake_release(root, 0)
    {:ok, probe_pid} = Agent.start_link(fn -> 0 end)

    # The probe yields nothing after pull and bootstrap (no refresh), then
    # reports a refreshed release — the chain must stop there and hand
    # sync/verify to the new release.
    probe = fn _opts ->
      calls = Agent.get_and_update(probe_pid, fn n -> {n, n + 1} end)

      if calls < 2, do: {:ok, nil}, else: {:ok, release}
    end

    {:ok, exec_pid} = Agent.start_link(fn -> [] end)

    executor = fn %{"step" => step} ->
      Agent.update(exec_pid, &[step | &1])
      :ok
    end

    output =
      ExUnit.CaptureIO.capture_io(:stdio, fn ->
        assert :ok = Plain.run(:update, destination: "HOME", executor: executor, handoff_probe: probe)
      end)

    assert Agent.get(exec_pid, &Enum.reverse/1) == ["pull", "bootstrap", "apply"]

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

  test "a nonzero child exit fails the run with the child's status", %{root: root} do
    release = fake_release(root, 3)
    probe = fn _opts -> {:ok, release} end

    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert catch_exit(
                 ExUnit.CaptureIO.capture_io(:stdio, fn ->
                   Plain.run(:update, destination: "HOME",
                     executor: fn %{"step" => _step} -> :ok end, handoff_probe: probe
                   )
                 end)
               ) == {:shutdown, 4}
      end)

    assert output =~ "update failed under the handed-off release (exit 3)"
  end

  test "an invalid --resume-from list is a usage error, never a chain run" do
    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert catch_exit(
                 Plain.run(:update,
                   destination: "HOME",
                   executor: fn _payload -> flunk("the executor must not run for an invalid resume list") end,
                   handoff_probe: fn _opts -> {:ok, nil} end,
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
                   handoff_probe: fn _opts -> {:ok, nil} end,
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
                   handoff_probe: fn _opts -> {:ok, nil} end,
                   resume_from: ","
                 )
               ) == {:shutdown, 2}
      end)

    assert output =~ "requires a comma-separated step list"
  end

  test "a probe error fails the chain instead of continuing under stale code" do
    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert catch_exit(
                 Plain.run(:update,
                   destination: "HOME",
                   executor: fn %{"step" => _step} -> :ok end,
                   handoff_probe: fn _opts -> {:error, "cannot read the release handoff note: eacces"} end
                 )
               ) == {:shutdown, 4}
      end)

    assert output =~ "update failed at handoff: cannot read the release handoff note: eacces"
  end

  # The child stand-in: records its argv (space-joined, the resume contract
  # is what matters) and exits with the configured status.
  defp fake_release(root, exit_code) do
    bin = Path.join([root, "fake-release", "bin", "workstation"])
    File.mkdir_p!(Path.dirname(bin))

    File.write!(
      bin,
      "#!/bin/sh\nprintf '%s\\n' \"$*\" >> #{root}/child.argv\necho Updated\nexit #{exit_code}\n"
    )

    File.chmod!(bin, 0o755)
    Path.join([root, "fake-release"])
  end
end
