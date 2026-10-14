defmodule Workstation.Daemon.UpdateCheck do
  @moduledoc """
  The `update.check` op: passive update-availability detection.

  The daemon asks the INSTALL REPO's origin (the same repo the update
  verb's `pull` step fetches) whether the local branch is behind its
  remote counterpart: `git ls-remote origin refs/heads/<branch>` — a
  read-only query that never touches the working tree or refs — compared
  against the local `HEAD`. The answer is one of:

    * `%{"status" => "up_to_date"}`
    * `%{"status" => "behind", "local" => sha7, "remote" => sha7,
        "remote_ref" => "refs/heads/<branch>"}`
    * `%{"status" => "unknown", "reason" => why}` — no origin, no git,
      offline, timeout: unknown NEVER nags. Offline must look like no-news.

  Contract notes: the check is daemon-side ONLY (the client stays thin —
  the op exists so the TUI's indicator and the status verb share one
  truth), read-only, bounded (`@ls_remote_timeout_ms`), and TTL-cached
  (10 min — a screen-open check must never hammer the remote). Git runs
  with the engine's config-isolation env (same contract as the pull step:
  the operator's ambient git configuration must not influence the
  comparison, and a credential prompt must never hang the daemon).
  """

  use GenServer

  require Logger

  @ttl_ms 10 * 60 * 1_000
  @ls_remote_timeout_ms 5_000
  @short_sha 7

  @typedoc "The three-state availability verdict (wire-shaped, string-keyed)."
  @type verdict :: map()

  @doc false
  def system_clock, do: System.system_time(:millisecond)

  # --- direct (uncached) surface -------------------------------------------

  @doc """
  Run one uncached check. Options: `:repo` (override the engine-repo
  resolution — tests pin a local fixture), `:clock` (zero-arity ms clock —
  TTL tests inject one), `:fetch` (`fun(repo, branch, remote_ref) ::
  {output, status} | {:error, term}` — the ls-remote seam), `:timeout_ms`.
  NEVER raises: every failure folds into `"unknown"` with a reason.
  """
  @spec check(keyword()) :: verdict()
  def check(opts \\ []) when is_list(opts) do
    clock = opts[:clock] || (&system_clock/0)

    case check_with_cache(nil, 0, clock, opts) do
      {verdict, _expiry} -> verdict
    end
  end

  # --- cached op surface (supervised child) ---------------------------------

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Map.new(opts), name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts || []]}, type: :worker}
  end

  @doc "One TTL-cached check (the op surface)."
  @spec check_cached(GenServer.server()) :: verdict()
  def check_cached(name \\ __MODULE__), do: GenServer.call(name, :check)

  @doc "Drop the cached verdict (tests)."
  @spec reset(GenServer.server()) :: :ok
  def reset(name \\ __MODULE__), do: GenServer.call(name, :reset)

  @impl true
  def init(state) do
    {:ok, Map.put_new(state, :cache, nil)}
  end

  @impl true
  def handle_call(:check, _from, state) do
    clock = state[:clock] || (&system_clock/0)
    {verdict, expiry} = check_with_cache(state[:cache], @ttl_ms, clock, Map.to_list(state))
    {:reply, verdict, %{state | cache: {verdict, expiry}}}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | cache: nil}}
  end

  # TTL read-through: a fresh cached verdict is returned as-is; anything
  # else (no cache, expired) re-checks and stamps a new expiry.
  defp check_with_cache(cache, ttl_ms, clock, opts) do
    now = clock.()

    case cache do
      {verdict, expiry} when is_integer(expiry) and expiry > now -> {verdict, expiry}
      _cache_miss -> {run_check(opts), now + ttl_ms}
    end
  end

  ## the check itself

  defp run_check(opts) do
    repo = opts[:repo] || resolved_repo()

    cond do
      # Status-wire callers run with the check disabled by default (tests
      # must never touch a network); the op surface resolves for real.
      repo == :disabled ->
        %{"status" => "unknown", "reason" => "update check disabled"}

      is_binary(repo) and File.dir?(Path.join(repo, ".git")) ->
        check_repo(repo, opts)

      is_binary(repo) ->
        %{"status" => "unknown", "reason" => "no git repository at #{repo}"}

      true ->
        %{"status" => "unknown", "reason" => "engine repository not found"}
    end
  rescue
    error -> %{"status" => "unknown", "reason" => inspect(error)}
  end

  # The install repo is the same checkout the update verb's pull step
  # fetches: the engine repo resolution (WORKSTATION_ENGINE_REPO, else the
  # checkout walk). `Application.get_env(:daemon, :update_check_repo)` pins
  # it explicitly (tests, or a daemon serving a relocated checkout).
  defp resolved_repo do
    case Application.get_env(:daemon, :update_check_repo) do
      nil ->
        # Disabled unless the daemon boot opted in: the status-wire merge
        # must never fire an unplanned network query (tests boot trees
        # without the opt-in). The op surface sets the repo or the opt-in
        # explicitly.
        if Application.get_env(:daemon, :update_check, false), do: engine_repo(), else: :disabled

      repo ->
        repo
    end
  end

  defp engine_repo do
    Workstation.Core.Update.engine_root([])
  rescue
    _ -> nil
  end

  defp check_repo(repo, opts) do
    with {:ok, branch} <- git(repo, ["rev-parse", "--abbrev-ref", "HEAD"], opts),
         branch = String.trim_trailing(branch),
         {:ok, local} <- git(repo, ["rev-parse", "HEAD"], opts) do
      # A detached or unborn HEAD has no remote counterpart to compare
      # against — unknown, never a guess.
      if branch == "" or branch == "HEAD" do
        %{"status" => "unknown", "reason" => "detached or unborn HEAD"}
      else
        compare(repo, branch, "refs/heads/#{branch}", String.trim_trailing(local), opts)
      end
    else
      {:error, reason} -> %{"status" => "unknown", "reason" => reason}
    end
  end

  defp compare(repo, branch, remote_ref, local, opts) do
    fetch = opts[:fetch] || default_fetch(repo, opts)
    timeout = opts[:timeout_ms] || @ls_remote_timeout_ms

    # Order matters: the fetch returns {output, exit-code} tuples OR
    # {:error, reason}; the two-tuple catch-all must come LAST or it
    # swallows the timeout/failure clauses (found as compile warnings).
    case fetch.(repo, branch, remote_ref) do
      {output, 0} ->
        case remote_head(output, remote_ref) do
          {:ok, remote} when remote == local ->
            %{"status" => "up_to_date"}

          {:ok, remote} ->
            %{"status" => "behind", "local" => short(local), "remote" => short(remote), "remote_ref" => remote_ref}

          :error ->
            %{"status" => "unknown", "reason" => "remote has no branch #{branch}"}
        end

      {:error, :timeout} ->
        %{"status" => "unknown", "reason" => "git ls-remote timed out after #{timeout} ms"}

      {:error, reason} ->
        %{"status" => "unknown", "reason" => "git ls-remote failed: #{inspect(reason)}"}

      {_output, _status} ->
        %{"status" => "unknown", "reason" => "cannot reach the git remote (offline?)"}
    end
  end

  defp default_fetch(repo, _opts) do
    fn _repo, _branch, remote_ref ->
      run_bounded(repo, ["ls-remote", "origin", remote_ref])
    end
  end

  # ls-remote is a NETWORK call: bounded via task yield + brutal kill, so a
  # hanging remote can never wedge the op (the timeout is the contract).
  defp run_bounded(repo, args) do
    task = Task.async(fn -> git_raw(repo, args) end)

    case Task.yield(task, @ls_remote_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  # One "sha<TAB>ref" line per match; the query pins exactly one ref.
  defp remote_head(output, remote_ref) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(:error, fn line ->
      case String.split(line, ~r/\t+/, parts: 2) do
        [sha, ^remote_ref] when byte_size(sha) >= @short_sha -> {:ok, sha}
        _other -> nil
      end
    end)
  end

  defp short(sha), do: binary_part(sha, 0, @short_sha)

  # Same config-isolated git contract as the pull step and the refresh
  # staleness probe: the operator's ambient git configuration must not
  # influence engine reads, and a credential prompt must never hang.
  defp git(repo, args, opts) do
    # {:error, reason} MUST precede the {_out, _status} catch-all: a
    # two-tuple error result also matches the generic exit-code clause.
    case (opts[:fetch_raw] || &git_raw/2).(repo, args) do
      {out, 0} -> {:ok, out}
      {:error, reason} -> {:error, "git #{hd(args)} failed: #{inspect(reason)}"}
      {_out, _status} -> {:error, "git #{hd(args)} failed"}
    end
  end

  defp git_raw(repo, args) do
    System.cmd("git", ["-C", repo | args],
      stderr_to_stdout: true,
      env: [
        {"GIT_CONFIG_NOSYSTEM", "1"},
        {"GIT_CONFIG_GLOBAL", "/dev/null"},
        {"GIT_CONFIG_SYSTEM", "/dev/null"},
        {"GIT_TERMINAL_PROMPT", "0"}
      ]
    )
  end
end
