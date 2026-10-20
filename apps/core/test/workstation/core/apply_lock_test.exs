defmodule Workstation.Core.ApplyLockTest do
  @moduledoc """
  The apply lock's holder judgment, against real filesystem fixtures: a
  live holder refuses (owner line verbatim, pid named), a holder provably
  dead on this host is taken over WITH an audit record (the
  bootstrap-after-kill recovery), a pid-less lock is never judged and never
  stolen, and a path that is not an owned regular file is never removed.
  All fixtures live in temporary directories; the real HOME is never touched.
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


  alias Workstation.Core.{ApplyLock, CanonicalJSON, EngineState, JSON}

  setup do
    home = unique_home("workstation-apply-lock")
    File.mkdir_p!(home)
    previous = System.get_env("WORKSTATION_HOME")
    System.put_env("WORKSTATION_HOME", home)

    on_exit(fn ->
      if previous, do: System.put_env("WORKSTATION_HOME", previous), else: System.delete_env("WORKSTATION_HOME")
    end)

    %{state_root: make_state_root(home)}
  end

  test "a fresh acquisition records a parseable pid beside the owner line and releases by token", %{state_root: state_root} do
    assert {:ok, token, path} = ApplyLock.acquire(state_root, "test work")

    assert {:ok, body} = EngineState.read_json(path)
    assert body["owner"] == "uid=#{EngineState.uid()} node=#{inspect(node())} (pid #{os_pid()})"
    assert body["pid"] == os_pid()
    assert body["purpose"] == "test work"

    # The lock is private state: created 0600 like the contract says.
    assert :erlang.band(File.stat!(path).mode, 0o777) == 0o600

    assert :ok = ApplyLock.release(path, token)
    refute File.exists?(path)
  end

  test "a stale lock whose holder pid is dead is taken over, audited, and released cleanly", %{state_root: state_root} do
    lock = ApplyLock.lock_path(state_root)
    dead = dead_pid()
    write_holder(lock, dead, "killed.mid-run")

    assert {:ok, token, path} = ApplyLock.acquire(state_root, "next run")

    # The debris is replaced by OUR lock, not reused.
    assert {:ok, body} = EngineState.read_json(path)
    assert body["pid"] == os_pid()

    # The takeover is on the record: one JSONL line naming the stale holder.
    audit = ApplyLock.audit_path(state_root)
    assert File.exists?(audit)
    assert :erlang.band(File.stat!(audit).mode, 0o777) == 0o600

    assert {:ok, [record]} = audit_lines(audit)
    assert record["event"] == "stale_lock_takeover"
    assert record["stale_pid"] == dead
    assert record["stale_owner"] =~ "(pid #{dead})"
    assert record["new_purpose"] == "next run"
    assert is_integer(record["new_pid"])

    assert :ok = ApplyLock.release(path, token)
    refute File.exists?(lock)

    # The audit trail outlives the lock: it is the history, not the state.
    assert File.exists?(audit)
  end

  test "a live holder refuses with its recorded owner line and is never taken over", %{state_root: state_root} do
    assert {:ok, first_token, lock} = ApplyLock.acquire(state_root, "held by this test")

    assert {:error, {:locked, owner, ^lock}} = ApplyLock.acquire(state_root, "contending work")
    assert owner == "uid=#{EngineState.uid()} node=#{inspect(node())} (pid #{os_pid()})"

    # No takeover happened: the recorded holder and the lock are untouched,
    # and there is no audit line about a lock that was never judged stale.
    assert {:ok, %{"token" => token_string}} = EngineState.read_json(lock)
    assert token_string == inspect(first_token)
    refute File.exists?(ApplyLock.audit_path(state_root))

    assert :ok = ApplyLock.release(lock, first_token)
  end

  test "a pid-less lock (pre-pid release or hand-written) fails closed with the recorded owner", %{state_root: state_root} do
    lock = ApplyLock.lock_path(state_root)
    owner_line = "uid=1000 node=test@host (pid 4242)"
    File.write!(lock, CanonicalJSON.encode(%{"owner" => owner_line}))

    assert {:error, {:locked, ^owner_line, ^lock}} = ApplyLock.acquire(state_root, "next run")

    # Unknowable means untouched: no removal, no audit, no judgment.
    assert {:ok, %{"owner" => ^owner_line}} = EngineState.read_json(lock)
    refute File.exists?(ApplyLock.audit_path(state_root))
  end

  test "a path that is not an owned regular file is never removed", %{state_root: state_root} do
    # The dead-pid verdict is not enough: the takeover's no-follow proof
    # requires an owned regular file at the path, so a planted link is a
    # refusal — and its target survives.
    target = Path.join(state_root, "planted-lock-target")
    write_holder(target, dead_pid(), "killed.mid-run")
    lock = ApplyLock.lock_path(state_root)
    :ok = File.ln_s(target, lock)

    assert {:error, {:locked, owner, ^lock}} = ApplyLock.acquire(state_root, "next run")
    assert owner =~ "not a regular file"

    assert File.exists?(target)
    assert File.exists?(lock)
    refute File.exists?(ApplyLock.audit_path(state_root))
  end

  test "an unreadable or malformed lock body refuses instead of racing", %{state_root: state_root} do
    lock = ApplyLock.lock_path(state_root)
    File.write!(lock, "{not json")

    assert {:error, {:locked, "unreadable or malformed lock", ^lock}} = ApplyLock.acquire(state_root, "next run")

    assert File.exists?(lock)
    refute File.exists?(ApplyLock.audit_path(state_root))
  end

  ## fixtures

  defp make_state_root(home) do
    root = Path.join([home, ".local", "state", "workstation"])
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    root
  end

  # A REAL dead pid: a shell that is gone by the time the judge reads — the
  # killed-beam debris the takeover exists for, never a fabricated number.
  defp dead_pid do
    {out, 0} = System.cmd("sh", ["-c", "echo $$"])
    String.to_integer(String.trim(out))
  end

  defp write_holder(path, pid, purpose) do
    File.write!(
      path,
      CanonicalJSON.encode(%{
        "owner" => "uid=1000 node=killed.host (pid #{pid})",
        "pid" => pid,
        "purpose" => purpose,
        "token" => "#Reference<0.1.2.3>"
      })
    )
  end

  defp audit_lines(audit) do
    audit
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      case JSON.decode(line) do
        {:ok, record} -> record
        {:error, :malformed} -> flunk("malformed audit line: #{line}")
      end
    end)
    |> then(&{:ok, &1})
  end

  defp os_pid, do: :os.getpid() |> List.to_string() |> String.to_integer()
end
