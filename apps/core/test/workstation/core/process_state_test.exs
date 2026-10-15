defmodule Workstation.Core.ProcessStateTest do
  @moduledoc """
  The shared pid liveness verdict (`Workstation.Core.ProcessState`): the
  `/proc/<pid>/stat` state character decides, `Z` is EXITED, and only an
  unreadable probe falls back to `kill -0` — fail closed. The zombie branch
  is pinned with the exact stat shapes of the 2026-10-15 bare-box rehearsal,
  because a healthy pid 1 reaps and a live zombie cannot be kept in a
  portable test; the wiring (a real exited pid reads dead through the
  production probe) is pinned against the OS itself.
  """

  use ExUnit.Case, async: true

  alias Workstation.Core.ProcessState

  test "the /proc stat verdict counts a zombie as exited (the bare-box defect: pid 1 never reaps)" do
    # The rehearsal's exact shape: the process exited, the container's
    # `sleep infinity` pid 1 never reaped it, and the defunct entry sat in
    # /proc with ppid 1 — `[beam.smp] <defunct>` — while `kill -0` kept
    # answering alive.
    zombie_stat =
      "3340 (beam.smp) Z 1 3290 3290 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 " <>
        "883100938 905675264 18446744073709551615 1 1 0 0 0 0 0 16777216 " <>
        "134222336 32729 BEST_EFFORT 0 0 0 17 2 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"

    assert ProcessState.stat_alive?(zombie_stat) == false
  end

  test "the /proc stat verdict: live states are alive, the comm's own parens don't fool it, unparseable text defers" do
    for state <- ["R", "S", "D", "T", "t", "I"] do
      assert ProcessState.stat_alive?("3340 (beam.smp) #{state} 1 3290 3290 0 -1 4194560") ==
               true,
             "state #{state} must read as alive"
    end

    # comm is free text: a comm carrying spaces and parentheses must not
    # shift the state field (the verdict reads past the LAST `)`).
    assert ProcessState.stat_alive?("12 (a) comm (with) parens ) S 0 1 1 0 -1") == true
    assert ProcessState.stat_alive?("3340 (weird (comm)) Z 1 1 1 0 -1") == false

    # Anything the parser cannot pin a state character on defers to the
    # caller's `kill -0` fallback.
    assert ProcessState.stat_alive?("not a stat line") == nil
    assert ProcessState.stat_alive?("3340 (beam.smp)   ") == nil
    assert ProcessState.stat_alive?("") == nil
  end

  test "the production probe: the running VM's own pid is alive, as integer and as the owner-file digit string" do
    os_pid = :os.getpid() |> List.to_string()

    assert ProcessState.alive?(String.to_integer(os_pid)) == true
    assert ProcessState.alive?(os_pid) == true
  end

  test "the production probe: a real exited pid is dead, whatever form carries it" do
    # A REAL dead pid: a shell gone by the time the probe reads (the beam
    # has reaped it) — never a fabricated number.
    {out, 0} = System.cmd("sh", ["-c", "echo $$"])
    dead = String.trim(out)

    assert ProcessState.alive?(String.to_integer(dead)) == false
    assert ProcessState.alive?(dead) == false
  end

  test "an unclear pid reads ALIVE — the probe never manufactures a death" do
    # A non-numeric owner pid names no provable process: a lock judge must
    # refuse, a wait must keep waiting — fail closed.
    assert ProcessState.alive?("not-a-pid") == true
    assert ProcessState.alive?("") == true
    assert ProcessState.alive?(0) == true
    assert ProcessState.alive?(-1) == true
  end
end
