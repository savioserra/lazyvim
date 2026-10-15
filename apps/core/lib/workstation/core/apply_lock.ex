defmodule Workstation.Core.ApplyLock do
  @moduledoc """
  Layer: kernel. The kernel law: this module names no package, no backend and no
  consumer -- it speaks only contracts and shapes (docs/architecture.md,
  "Module hierarchy & moduledoc conventions").
  The engine's one apply lock: `<state_root>/apply.lock`, the same file the
  daemon orchestrator takes for every apply-shaped mutation, so no two
  apply-shaped mutations can ever run concurrently against one target home —
  mutual exclusion is a filesystem fact, not a convention between processes.

  Semantics (shared contract, enforced here for every caller):

  * the lock is created exclusively (`wx`, mode 0600) and its body is JSON
    carrying a parseable holder record: `owner` (the operator-facing
    `uid=… node=… (pid …)` line), `pid` (the holder's OS pid — the takeover
    judge's input; the token alone was an uncheckable term blob), `purpose`
    and `token`;
  * when the lock already exists the recorded holder decides, never a mtime
    or size guess: a holder whose pid is ALIVE is reported and the
    acquisition FAILS CLOSED — the refusal is the recorded owner line (pid
    included), and a live holder is never interrupted;
  * a holder whose pid is PROVABLY DEAD ON THIS HOST (the shared
    `/proc/<pid>/stat` judge, `Workstation.Core.ProcessState`: the kernel's
    own state character decides and a zombie is exited — a holder that
    exited but awaits reap cannot run code, so it cannot hold the lock) is
    debris from a killed beam (the cross-generation stop gap),
    and the lock is TAKEN OVER: only after a fresh no-follow check that the
    path is still a regular file owned by this account (the lock's mirror of
    the daemon's owned-socket proof — anything else is never deleted), the
    debris is removed and the create retried, and the takeover is recorded
    as one JSONL line in `<state_root>/apply.lock.audit`. A takeover that
    cannot be recorded is refused, never silent, and the just-created lock
    is released again — audit and acquisition stand or fall together;
  * a lock without a parseable pid (written by a pre-pid release or by
    hand) is unknowable and is never judged: the recorded owner is reported
    verbatim and removal stays a deliberate operator action;
  * an unreadable or malformed lock body is reported as
    "unreadable or malformed lock" instead of being treated as absent, so a
    corrupted lock cannot silently re-enable concurrency;
  * a holder releases only its OWN invocation: the release re-reads the file
    and removes it only when the recorded token still matches, which is the
    portable equivalent of an fd-handle release when another operation
    replaced the lock in between;
  * an environment error (permissions, missing state tree) must look exactly
    like a held lock to the caller, never like "free".
  """

  @lock_name "apply.lock"
  @audit_name "apply.lock.audit"
  @lock_mode 0o600
  # The takeover loop is bounded: each round re-creates exclusively and
  # re-judges whatever appeared in between, and a refusal — never a spin —
  # ends the contention.
  @takeover_attempts 3
  # S_IFMT/S_IFREG file-type bits, bit-masked exactly like the daemon's
  # owned-socket proof: the takeover deletes only a REGULAR FILE owned by
  # this account, never whatever else may have appeared at the path.
  @s_ifmt 0o170000
  @s_ifreg 0o100000

  @doc "The lock file path for one state root (exposed for tests and diagnostics)."
  @spec lock_path(String.t()) :: String.t()
  def lock_path(state_root), do: Path.join(state_root, @lock_name)

  @doc "The takeover audit trail path for one state root (exposed for tests and diagnostics)."
  @spec audit_path(String.t()) :: String.t()
  def audit_path(state_root), do: Path.join(state_root, @audit_name)

  @doc """
  Acquire the state root's apply lock. Returns `{:ok, token, path}` or
  `{:error, {:locked, owner, path}}` — never waits. A lock whose holder is
  provably dead on this host is taken over with an audit record; a live
  holder, a pid-less lock and every environment error refuse.
  """
  @spec acquire(String.t(), String.t()) ::
          {:ok, reference(), String.t()} | {:error, {:locked, String.t(), String.t()}}
  def acquire(state_root, purpose),
    do: try_acquire(lock_path(state_root), purpose, nil, @takeover_attempts)

  # `takeover` carries the judged-dead holder of the round whose debris this
  # call's create replaced (nil on a clean first create); `attempts` bounds
  # the takeover loop.
  defp try_acquire(path, purpose, takeover, attempts) do
    token = make_ref()

    body =
      Workstation.Core.CanonicalJSON.encode(%{
        "owner" => owner_metadata(),
        "pid" => os_pid(),
        "purpose" => purpose,
        "token" => reference_string(token)
      })

    # :file (not Elixir File.open/3) because the lock must be private from
    # creation; Elixir's File.open has no mode argument.
    case :file.open(String.to_charlist(path), [:exclusive, :write, {:mode, 0o600}]) do
      {:ok, file} ->
        # The OTP 28 file server ignores the create mode (probed: the node
        # lands 0644), so the private mode is enforced the way the daemon
        # hardens its socket node: explicitly, before the body is written.
        :ok = File.chmod(path, @lock_mode)
        :ok = :file.write(file, body)
        :ok = :file.close(file)

        case record_takeover(path, takeover, purpose, token) do
          :ok ->
            {:ok, token, path}

          {:error, reason} ->
            # All-or-nothing: a takeover that cannot be recorded is refused,
            # and the lock this call just created is released again (its own
            # token), so the next attempt re-judges a clean filesystem.
            _ = release(path, token)

            {:error,
             {:locked, "stale lock takeover could not be recorded (#{inspect(reason)})", path}}
        end

      {:error, :eexist} ->
        judge_existing(path, purpose, attempts, takeover)

      {:error, reason} ->
        # Fail closed: an environment error (permissions, missing state tree)
        # must look exactly like a held lock to the caller, never like "free".
        {:error, {:locked, "lock unavailable (#{inspect(reason)})", path}}
    end
  end

  # The holder verdict on an existing lock: alive refuses (owner line verbatim,
  # pid included), dead takes over (bounded), unknowable refuses (removal stays
  # the operator's deliberate action), a mid-refusal release re-races the create.
  defp judge_existing(path, purpose, attempts, takeover) do
    case judge_holder(path) do
      {:alive, owner} ->
        {:error, {:locked, owner, path}}

      {:unknowable, owner} ->
        {:error, {:locked, owner, path}}

      {:free_race} ->
        try_acquire(path, purpose, takeover, attempts - 1)

      {:dead, stale} when attempts > 1 ->
        case remove_owned_debris!(path) do
          :ok -> try_acquire(path, purpose, stale, attempts - 1)
          {:error, owner} -> {:error, {:locked, owner, path}}
        end

      {:dead, stale} ->
        {:error, {:locked, stale.owner, path}}
    end
  end

  @doc """
  Release the lock only if `token` still identifies the current lock file.
  """
  @spec release(String.t(), reference()) :: :ok | {:error, :not_owner}
  def release(path, token) do
    expected = reference_string(token)

    case Workstation.Core.EngineState.read_json(path) do
      {:ok, %{"token" => recorded}} when recorded == expected ->
        case File.rm(path) do
          :ok -> :ok
          {:error, reason} -> {:error, {:not_owner, reason}}
        end

      _other ->
        # Someone else owns the file now (or it is gone); leave it alone.
        {:error, :not_owner}
    end
  end

  ## holder judgment

  # The verdict comes from the lock's own recorded fields. The pid field is
  # the takeover judge's input; a lock without one is unknowable and is
  # never judged.
  defp judge_holder(path) do
    case read_holder(path) do
      {:ok, %{owner: owner, pid: pid}} ->
        if holder_alive?(pid),
          do: {:alive, owner_with_pid(owner, pid)},
          else: {:dead, %{owner: owner_with_pid(owner, pid), pid: pid}}

      {:ok, %{owner: owner}} ->
        {:unknowable, owner}

      {:error, owner} ->
        {:unknowable, owner}

      :free_race ->
        {:free_race}
    end
  end

  defp read_holder(path) do
    try do
      case Workstation.Core.EngineState.read_json(path) do
        {:ok, %{"owner" => owner} = body} when is_binary(owner) ->
          case body do
            %{"pid" => pid} when is_integer(pid) and pid > 0 -> {:ok, %{owner: owner, pid: pid}}
            _other -> {:ok, %{owner: owner}}
          end

        {:ok, _other} ->
          {:error, "unreadable or malformed lock"}

        {:error, :malformed} ->
          {:error, "unreadable or malformed lock"}

        :absent ->
          # The holder released between the failed create and this read.
          :free_race
      end
    rescue
      # read_json's file guard raises on a symlinked or foreign-owned lock —
      # that is a refused lock, never a crash.
      error in [ArgumentError] -> {:error, "lock unusable (#{Exception.message(error)})"}
    end
  end

  # The same "provably dead ON THIS HOST" judge the runtime installer lock
  # uses, and every other probe: the shared liveness verdict
  # (`Workstation.Core.ProcessState`). The `/proc/<pid>/stat` state character
  # decides and a zombie state (`Z`) is EXITED — the kernel's own proof the
  # holder exited; a zombie cannot run code, so it cannot hold the lock, and
  # taking over is exactly the killed-beam recovery the takeover exists for.
  # (Under a pid 1 that never reaps the defunct entry outlives the death, and
  # the old `/proc` existence probe read it as alive, refusing every apply.)
  # The fail-closed posture is intact: an unclear probe — unreadable stat,
  # inconclusive `kill -0` — still reads ALIVE. A takeover must be provable,
  # never probable; the cost of an unclear probe is one refused apply, never
  # a stolen lock.
  defp holder_alive?(pid) when is_integer(pid) and pid > 0,
    do: Workstation.Core.ProcessState.alive?(pid)

  defp holder_alive?(_unparsable), do: true

  # Deleting the debris only after a fresh no-follow check that it is still a
  # regular file owned by this account (the lock's mirror of the daemon's
  # owned-socket proof): between the failed create and this check the path
  # may have been replaced by anything, and the engine never deletes a file
  # it cannot prove is its own dead lock.
  defp remove_owned_debris!(path) do
    if owned_lock_file?(path) do
      case File.rm(path) do
        :ok -> :ok
        {:error, reason} -> {:error, "stale lock removal failed (#{inspect(reason)})"}
      end
    else
      {:error, "stale lock at #{path} is not an owned regular file; refusing to remove it"}
    end
  end

  defp owned_lock_file?(path) do
    case File.lstat(path) do
      {:ok, stat} ->
        :erlang.band(stat.mode, @s_ifmt) == @s_ifreg and
          stat.uid == Workstation.Core.EngineState.uid()

      {:error, _reason} ->
        false
    end
  end

  ## audit trail

  # The audit line is appended only AFTER the new lock is held (a record
  # never precedes the fact): the stale holder's owner text and pid, the new
  # purpose and token — the operator-facing answer to "why did my apply.lock
  # change underneath me".
  defp record_takeover(_path, nil, _purpose, _token), do: :ok

  defp record_takeover(path, stale, purpose, token) do
    entry =
      Workstation.Core.CanonicalJSON.encode(%{
        "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "event" => "stale_lock_takeover",
        "new_pid" => os_pid(),
        "new_purpose" => purpose,
        "new_token" => reference_string(token),
        "stale_owner" => stale.owner,
        "stale_pid" => stale.pid
      })

    append_audit_line(audit_path(Path.dirname(path)), entry <> "\n")
  end

  defp append_audit_line(audit_path, line) do
    if File.exists?(audit_path) do
      File.open(audit_path, [:append], &IO.binwrite(&1, line))
    else
      case :file.open(String.to_charlist(audit_path), [:exclusive, :write, {:mode, 0o600}]) do
        {:ok, file} ->
          # Same create-mode enforcement as the lock itself (the file server
          # ignores the mode option on the pinned OTP).
          :ok = File.chmod(audit_path, @lock_mode)
          result = :file.write(file, line)
          :ok = :file.close(file)
          result

        # A racing takeover created the trail first; fall through to append.
        {:error, :eexist} ->
          File.open(audit_path, [:append], &IO.binwrite(&1, line))

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  ## holder metadata

  defp owner_metadata do
    "uid=#{Workstation.Core.EngineState.uid()} node=#{inspect(node())} (pid #{os_pid()})"
  end

  # The owner line names the pid even when a hand-written record's owner
  # string omits it — the refusal must always name WHO holds the lock.
  defp owner_with_pid(owner, pid) do
    if String.contains?(owner, "(pid "), do: owner, else: "#{owner} (pid #{pid})"
  end

  defp os_pid, do: :os.getpid() |> List.to_string() |> String.to_integer()

  defp reference_string(ref), do: inspect(ref)
end
