defmodule Workstation.Core.ApplyLock do
  @moduledoc """
  The engine's one apply lock: `<state_root>/apply.lock`, the same file the
  one-shot CLI apply and the daemon orchestrator take, so no two apply-shaped
  mutations can ever run concurrently against one target home — mutual
  exclusion is a filesystem fact, not a convention between processes.

  Semantics (shared contract, enforced here for every caller):

  * the lock is created exclusively (`wx`, mode 0600); when it already exists
    the recorded owner metadata is reported and the acquisition FAILS CLOSED
    — stale locks are never stolen, recovery is always the operator
    inspecting the recorded owner and removing the file deliberately;
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

  @doc "The lock file path for one state root (exposed for tests and diagnostics)."
  @spec lock_path(String.t()) :: String.t()
  def lock_path(state_root), do: Path.join(state_root, @lock_name)

  @doc """
  Acquire the state root's apply lock. Returns `{:ok, token, path}` or
  `{:error, {:locked, owner, path}}` — never waits, never steals.
  """
  @spec acquire(String.t(), String.t()) ::
          {:ok, reference(), String.t()} | {:error, {:locked, String.t(), String.t()}}
  def acquire(state_root, purpose) do
    path = lock_path(state_root)
    token = make_ref()
    body = Workstation.Core.CanonicalJSON.encode(%{"owner" => owner_metadata(), "purpose" => purpose, "token" => reference_string(token)})

    # :file (not Elixir File.open/3) because the 0600 mode must be set at
    # create time; Elixir's File.open has no mode argument.
    case :file.open(String.to_charlist(path), [:exclusive, :write, {:mode, 0o600}]) do
      {:ok, file} ->
        :ok = :file.write(file, body)
        :ok = :file.close(file)
        {:ok, token, path}

      {:error, :eexist} ->
        owner =
          case Workstation.Core.EngineState.read_json(path) do
            {:ok, %{"owner" => owner}} when is_binary(owner) -> owner
            {:ok, _other} -> "unreadable or malformed lock"
            :absent -> "unreadable or malformed lock"
            {:error, :malformed} -> "unreadable or malformed lock"
          end

        {:error, {:locked, owner, path}}

      {:error, reason} ->
        # Fail closed: an environment error (permissions, missing state tree)
        # must look exactly like a held lock to the caller, never like "free".
        {:error, {:locked, "lock unavailable (#{inspect(reason)})", path}}
    end
  end

  @doc "Release the lock only if `token` still identifies the current lock file."
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

  defp owner_metadata do
    "uid=#{Workstation.Core.EngineState.uid()} node=#{inspect(node())}"
  end

  defp reference_string(ref), do: inspect(ref)
end
