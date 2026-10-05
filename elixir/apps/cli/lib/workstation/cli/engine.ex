defmodule Workstation.CLI.Engine do
  @moduledoc """
  The one-shot in-process lifecycle driver behind the fused `workstation`
  CLI: `apply`, `bootstrap`, `sync`, `verify`, `pull`, and the per-step
  `run_step/2` that the update screens and plain runner chain in order.

  Every mutation runs in THIS process under the target home's exclusive apply
  lock — `Workstation.Core.ApplyLock`, `<state_root>/apply.lock`, the same
  file the daemon orchestrator takes — so a one-shot run and a daemon
  orchestration can never interleave on one home. There is no engine daemon
  on this path and no Lua: the CLI release binary IS the engine runtime.
  Plans are collected fresh through the shared Core composition
  (`Workstation.Core.Plan.composed_plan/2`), exactly like the daemon's
  applier; the baseline stamp makes a journal that advanced past a rendered
  screen a refusal, and an identical desired generation an idempotent no-op.

  Lock scope is PER STEP (mirroring the daemon's update chain): each mutating
  step acquires and releases around itself, so a step failure never wedges
  the lock and two concurrent chains interleave only at step boundaries.
  `verify/1` and `pull/1` touch no mutable home state and stay lockless.

  Error vocabulary: every failure is `{:error, code, message}` — `"locked"`
  under contention, otherwise a step code carrying the verbatim engine
  message (the preconditions raise `ArgumentError` with actionable text).
  The screens and the plain runner render the message, never a stacktrace.
  """

  alias Workstation.Core.{ApplyEngine, ApplyLock, EngineState, Plan, Update}

  @doc """
  One-shot apply: fresh live plan executed under the apply lock. The plan's
  own generation is the truth; `opts[:requested_generation]` (the confirm-
  exactly-what-you-saw contract from the apply screen) is passed through to
  the engine when present.
  """
  @spec apply(keyword()) :: {:ok, map()} | {:error, String.t(), String.t()}
  def apply(opts \\ []) when is_list(opts) do
    with_lock "apply.run", opts, fn ->
      with {:ok, plan} <- composed_plan(opts) do
        guarded(fn _opts ->
          params = %{"home" => home(opts)}

          params =
            case opts[:requested_generation] do
              nil -> params
              generation -> Map.put(params, "requested_generation", generation)
            end

          generation = ApplyEngine.execute(plan, params)

          %{"step" => "apply", "status" => "ok", "generation" => generation}
        end)
      end
    end
  end

  @doc """
  Run one lifecycle step. Mutating steps (`bootstrap`, `apply`, `sync`)
  acquire the apply lock around themselves; `pull` and `verify` are
  lockless. `opts` pass through to the core steps (`:home`, `:engine_root`,
  `:collector` for sandboxed plan injection).
  """
  @spec run_step(String.t(), keyword()) :: {:ok, map()} | {:error, String.t(), String.t()}
  def run_step(step, opts \\ []) when is_binary(step) and is_list(opts) do
    case step do
      "pull" -> guarded(&pull_record/1, opts, "update_failed")
      "bootstrap" -> with_lock("bootstrap.run", opts, fn -> bootstrap_locked(opts) end)
      "apply" -> with_lock("update.run step=apply", opts, fn -> apply_current(opts) end)
      "sync" -> with_lock("update.run step=sync", opts, fn -> guarded(&sync_record/1, opts, "update_failed") end)
      "verify" -> guarded(&verify_record/1, opts, "update_failed")
      other -> {:error, "update_failed", "unknown lifecycle step #{inspect(other)}"}
    end
  end

  @doc """
  Provision the destination home: the pinned managed tools (editor runtime
  and chezmoi backend, installed as capabilities), the launcher symlink, and
  — when the engine checkout ships a buildable release and a `mise`
  toolchain is present — a refresh of the installed release from source. The
  refresh is idempotent (an unchanged tree rebuilds to a no-op) and keeps
  the installed binary from going stale after `pull`.
  """
  @spec bootstrap(keyword()) :: {:ok, map()} | {:error, String.t(), String.t()}
  def bootstrap(opts \\ []) when is_list(opts) do
    with_lock("bootstrap.run", opts, fn -> bootstrap_locked(opts) end)
  end

  @doc "Reconcile the journal's generation with the freshly collected desired state."
  @spec sync(keyword()) :: {:ok, map()} | {:error, String.t(), String.t()}
  def sync(opts \\ []) when is_list(opts) do
    with_lock("sync.run", opts, fn -> guarded(&sync_record/1, opts, "sync_failed") end)
  end

  @doc "Verify the launcher symlink and every applied target fingerprint (read-only, lockless)."
  @spec verify(keyword()) :: {:ok, map()} | {:error, String.t(), String.t()}
  def verify(opts \\ []) when is_list(opts), do: guarded(&verify_record/1, opts, "verify_failed")

  @doc "Fast-forward the engine checkout (read-only for the home, lockless)."
  @spec pull(keyword()) :: {:ok, map()} | {:error, String.t(), String.t()}
  def pull(opts \\ []) when is_list(opts), do: guarded(&pull_record/1, opts, "pull_failed")

  ## step bodies

  defp pull_record(opts), do: elem(Update.Pull.run(core_opts(opts)), 1)

  defp sync_record(opts), do: elem(Update.Sync.run(core_opts(opts)), 1)

  defp verify_record(opts), do: elem(Update.Verify.run(core_opts(opts)), 1)

  defp bootstrap_locked(opts) do
    bootstrap_run = opts[:bootstrap_run] || (&Update.Bootstrap.run/1)

    with {:ok, record} <- guarded(fn _opts -> elem(bootstrap_run.(core_opts(opts)), 1) end, opts, "bootstrap_failed") do
      case release_refresh(opts) do
        {:ok, refreshed?} ->
          case refresh_note(refreshed?, opts) do
            :ok -> {:ok, Map.put(record, "release_refreshed", refreshed?)}
            {:error, message} -> {:error, "bootstrap_failed", message}
          end

        {:error, output} ->
          {:error, "bootstrap_failed", "release refresh failed:\n#{output}"}
      end
    end
  end

  # The release handoff note (docs/capabilities.md, "release refresh and
  # handoff"): a REFRESHED bootstrap leaves a note naming the release that
  # wrote it, because this process is still executing the OLD loaded code
  # while the on-disk release just changed under it; the plain runner
  # probes the note after every step and hands the remaining chain to the
  # new release. A non-refreshing bootstrap REMOVES any leftover note —
  # after a refresh-free bootstrap, this process and the disk agree, so a
  # stale note from an earlier crashed handoff must not trigger a spurious
  # handoff later.
  defp refresh_note(false, opts) do
    File.rm(update_handoff_path(opts))
    :ok
  end

  defp refresh_note(true, opts) do
    path = update_handoff_path(opts)

    case File.mkdir_p(Path.dirname(path)) do
      :ok -> write_handoff_note(path)
      {:error, reason} -> {:error, "cannot record the release handoff note: #{inspect(reason)}"}
    end
  end

  defp write_handoff_note(path) do
    note = Jason.encode!(%{"from_release" => :code.root_dir() |> to_string()})

    case File.write(path, note) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot record the release handoff note: #{inspect(reason)}"}
    end
  end

  @doc """
  Probe the release handoff note left by a refreshed bootstrap step.

  Returns `{:ok, release_root}` when the caller is still executing the
  release the note names — the on-disk release changed mid-run while this
  process keeps its old loaded code, so the remaining update steps belong
  to the new release (the plain runner re-execs it with `--resume-from`).
  The note deliberately SURVIVES this return: if the re-exec dies, the
  next update run re-derives the same handoff instead of silently
  finishing the chain under stale code.

  Returns `{:ok, nil}` when there is nothing to hand off — no note, or the
  caller already IS a different (newer) release than the note names, which
  is the handoff target case: the note is consumed so it cannot trigger
  another handoff later. A malformed note is an error, never a silent
  continue: the note is engine state this module wrote.
  """
  @spec update_handoff(keyword()) :: {:ok, String.t() | nil} | {:error, String.t()}
  def update_handoff(opts \\ []) when is_list(opts) do
    path = update_handoff_path(opts)

    case File.read(path) do
      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, "cannot read the release handoff note: #{inspect(reason)}"}

      {:ok, raw} ->
        case parse_note(raw) do
          {:ok, from_release} ->
            if from_release == current_release() do
              {:ok, from_release}
            else
              _ = File.rm(path)
              {:ok, nil}
            end

          :error ->
            {:error, "malformed release handoff note at #{path}"}
        end
    end
  end

  # Self-written state: exactly the one documented key, non-empty string.
  defp parse_note(raw) do
    case Jason.decode(raw) do
      {:ok, %{"from_release" => release}} when is_binary(release) and release != "" ->
        {:ok, release}

      _other ->
        :error
    end
  end

  # The release root of the code this process is executing (the OTP root
  # under the installed release; under mix it is the build tree's OTP
  # root — consistent within one process, which is all the identity
  # comparison needs).
  defp current_release, do: :code.root_dir() |> to_string()

  defp update_handoff_path(opts),
    do: Path.join([state_root(home(opts)), "update", "handoff.json"])

  defp apply_current(opts) do
    with {:ok, plan} <- composed_plan(opts) do
      # guarded/3 calls the closure with the step opts (fun.(opts)) — the
      # 0-arity variant BadArity-crashed the live update chain exactly here
      # (apply ok, then the apply step died before the engine ran). The
      # body is a single call into the NAMED apply_execute/2, so the step
      # contract stays grep-able and an arity drift dies inside a named
      # call with a clear stack, not as an anonymous BadArity.
      guarded(&apply_execute(plan, &1), opts)
    else
      {:error, message} -> {:error, "apply_failed", message}
    end
  end

  defp apply_execute(plan, opts) do
    generation = ApplyEngine.execute(plan, %{"home" => home(opts)})
    %{"step" => "apply", "status" => "ok", "generation" => generation}
  end

  # The shared Core composition (Plan.composed_plan/2), coded for this
  # surface: collection failures and engine preconditions both surface as a
  # plain `{:error, message}` the caller maps to its step code.
  defp composed_plan(opts) do
    case Plan.composed_plan(home(opts), opts[:collector]) do
      {:ok, plan} -> {:ok, plan}
      {:error, {:collect_failed, reason}} -> {:error, "plan collection failed: #{inspect(reason)}"}
      {:error, message} -> {:error, message}
    end
  end

  @doc """
  Refresh the installed engine release from the anchored checkout.

  This is the engine half of the update lifecycle's "release refresh"
  contract (docs/capabilities.md): the bootstrap step keeps the installed
  release from going stale after `pull`. Returns `{:ok, refreshed?}` where
  `refreshed?` is true only when the installer actually rebuilt and
  activated a release, `{:error, output}` when the build failed — a failed
  refresh aborts the chain instead of silently continuing under stale code.

  Gating, in order: a release is refreshable only when the engine checkout
  carries (or anchors) a buildable `elixir/` umbrella, the platform is one
  the launcher supports, and the `mise` toolchain is on PATH — anything
  else skips honestly (a release installed without a checkout manages its
  own acquisition; failing because a toolchain is absent is not an error).
  When the installed release carries a `.built-from` stamp equal to the
  checkout's current HEAD the refresh is a no-op: the on-disk release was
  already built from the source this update just pulled, so rebuilding it
  (and re-execing mid-chain) would be pure waste — this equality is also
  what makes the update handoff terminate.

  `opts[:installer]` injects the installer invocation for tests (same
  `System.cmd` result shape); production runs the checkout's own
  `bootstrap/install-runtime.sh` — the exact acquisition path a fresh
  machine takes.
  """
  @spec release_refresh(keyword()) :: {:ok, boolean()} | {:error, String.t()}
  def release_refresh(opts) when is_list(opts) do
    root = engine_root(opts)
    home = home(opts)

    with {:ok, anchor} <- build_anchor(root),
         {:ok, platform} <- platform(),
         true <- toolchain?() do
      if release_stale?(anchor, home) do
        run_installer(opts, root, anchor, platform, home)
      else
        {:ok, false}
      end
    else
      nil -> {:ok, false}
      false -> {:ok, false}
    end
  end

  ## release refresh plumbing

  # The repo anchor — the directory holding the elixir/ umbrella — mirrors
  # the launcher's resolution exactly: the checkout itself for a
  # self-contained engine tree, its parent for the standard
  # <repo>/workstation checkout layout. Without an anchor there is no
  # buildable release source and the refresh skips.
  defp build_anchor(root) do
    cond do
      File.exists?(Path.join(root, "elixir/mix.exs")) -> {:ok, root}
      Path.basename(root) == "workstation" and File.exists?(Path.join(root, "../elixir/mix.exs")) ->
        {:ok, Path.expand("..", root)}
      true -> nil
    end
  end

  # The installer needs the same platform tag the launcher derives. An
  # unsupported platform never runs a release at all, so there is nothing
  # to refresh.
  defp platform do
    arch = :erlang.system_info(:system_architecture) |> to_string()

    case :os.type() do
      {:unix, :linux} -> if arch =~ ~r/x86_64|amd64/, do: {:ok, "linux_x86_64"}
      {:unix, :darwin} -> if arch =~ ~r/arm64|aarch64/, do: {:ok, "darwin_arm64"}
      _ -> nil
    end
  end

  defp toolchain?, do: System.find_executable("mise") != nil

  # Staleness vs the pulled HEAD: the installer stamps every activated
  # release with the source HEAD it built from; a release whose stamp is
  # missing or differs from the checkout's current HEAD is stale. A
  # checkout that cannot answer rev-parse (not a git tree) is always
  # stale — rebuild, conservatively.
  defp release_stale?(anchor, home) do
    case release_stamp(home) do
      {:ok, stamp} -> stamp != checkout_head(anchor)
      :error -> true
    end
  end

  defp release_stamp(home) do
    path = Path.join([home, ".local", "opt", "workstation", ".built-from"])

    case File.read(path) do
      {:ok, stamp} -> {:ok, String.trim_trailing(stamp)}
      {:error, _} -> :error
    end
  end

  # Same config-isolated git contract as the pull step: the operator's
  # ambient git configuration must not influence which HEAD the refresh
  # compares against.
  defp checkout_head(anchor) do
    case System.cmd("git", ["-C", anchor, "rev-parse", "HEAD"],
           stderr_to_stdout: true,
           env: git_isolation()
         ) do
      {out, 0} -> String.trim_trailing(out)
      {_out, _code} -> nil
    end
  end

  defp git_isolation do
    [
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_SYSTEM", "/dev/null"},
      {"GIT_TERMINAL_PROMPT", "0"}
    ]
  end

  # The installer is shell, not downloaded code; it validates the checkout's
  # pins, installs the pinned editor runtime, and — pointed at the anchor by
  # WORKSTATION_ENGINE_REPO — builds and activates the release, stamping it
  # with the source HEAD. A non-zero exit is the refresh failure text.
  defp run_installer(opts, checkout, anchor, platform, home) do
    installer = Path.join(checkout, "bootstrap/install-runtime.sh")
    fun = opts[:installer] || default_installer(checkout, installer, platform, home, anchor)

    case fun.(anchor, home) do
      {_output, 0} -> {:ok, true}
      {output, _status} -> {:error, String.trim_trailing(output, "\n")}
    end
  end

  defp default_installer(checkout, installer, platform, home, anchor) do
    fn _anchor, _home ->
      System.cmd("sh", [installer, checkout, platform],
        env: [{"HOME", home}, {"WORKSTATION_ENGINE_REPO", anchor}],
        stderr_to_stdout: true
      )
    end
  end

  ## plumbing

  defp home(opts), do: Keyword.get(opts, :home) || EngineState.home()

  defp state_root(home), do: Path.join([home | EngineState.state_components()])

  defp engine_root(opts), do: Update.engine_root(core_opts(opts))

  defp core_opts(opts), do: opts |> Keyword.delete(:collector) |> Keyword.delete(:installer) |> Keyword.delete(:bootstrap_run)

  defp with_lock(purpose, opts, fun) do
    home = home(opts)
    state_root = state_root(home)

    # The lock lives inside the guarded state tree, and a fresh destination
    # has no tree yet: establish the write-side anchor before locking —
    # idempotent, final at 0700. The daemon only ever serves homes whose
    # tree already exists; the one-shot CLI is the first-boot path.
    EngineState.ensure_roots!(home)

    case ApplyLock.acquire(state_root, purpose) do
      {:ok, token, path} ->
        try do
          fun.()
        after
          ApplyLock.release(path, token)
        end

      {:error, {:locked, owner, _path}} ->
        {:error, "locked", "apply lock held by #{owner}"}
    end
  end

  # A step's engine failure surfaces verbatim: the message is the operator
  # interface (preconditions raise ArgumentError with actionable text), and
  # any engine raise folds to the step's error code, never a stacktrace.
  defp guarded(fun, opts \\ [], code \\ "apply_failed") do
    {:ok, fun.(opts)}
  rescue
    error in [ArgumentError] -> {:error, code, Exception.message(error)}
  end
end
