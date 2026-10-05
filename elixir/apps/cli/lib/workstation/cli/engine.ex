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
    with {:ok, record} <- guarded(fn _opts -> elem(Update.Bootstrap.run(core_opts(opts)), 1) end, opts, "bootstrap_failed") do
      case release_refresh(opts) do
        :ok -> {:ok, record}
        {:error, output} -> {:error, "bootstrap_failed", "release refresh failed:\n#{output}"}
      end
    end
  end

  defp apply_current(opts) do
    with {:ok, plan} <- composed_plan(opts) do
      # guarded/3 calls the closure with the step opts (fun.(opts)) — the
      # 0-arity variant BadArity-crashed the live update chain exactly here
      # (apply ok, then the apply step died before the engine ran).
      guarded(fn _opts ->
        generation = ApplyEngine.execute(plan, %{"home" => home(opts)})
        %{"step" => "apply", "status" => "ok", "generation" => generation}
      end)
    else
      {:error, message} -> {:error, "apply_failed", message}
    end
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

  ## release refresh

  # The refresh runs the shim's installer (the exact acquisition path a fresh
  # machine takes), pointed at the engine checkout with the destination home
  # as HOME. Output matters only when it fails.
  defp release_refresh(opts) do
    root = engine_root(opts)
    home = home(opts)

    if release_refreshable?(root) do
      installer = Path.join(root, "bootstrap/install-runtime.sh")

      case System.cmd("sh", [installer, root],
             env: [{"HOME", home}, {"WORKSTATION_ENGINE_REPO", root}],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, _status} -> {:error, String.trim_trailing(output, "\n")}
      end
    else
      :ok
    end
  end

  # The refresh needs a buildable release source and the toolchain that
  # builds it. A release installed without an engine checkout (or without
  # mise on PATH) manages its own acquisition: skipping is the honest
  # answer, failing because a toolchain is absent is not.
  defp release_refreshable?(root),
    do: File.exists?(Path.join(root, "elixir/mix.exs")) and System.find_executable("mise") != nil

  ## plumbing

  defp home(opts), do: Keyword.get(opts, :home) || EngineState.home()

  defp state_root(home), do: Path.join([home | EngineState.state_components()])

  defp engine_root(opts), do: Update.engine_root(core_opts(opts))

  defp core_opts(opts), do: Keyword.delete(opts, :collector)

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
