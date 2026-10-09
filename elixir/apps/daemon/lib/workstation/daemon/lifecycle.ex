defmodule Workstation.Daemon.Lifecycle do
  @moduledoc """
  The daemon-side lifecycle executor — the ONLY mutation engine surface
  since the client/server refactor. The `bootstrap.run`, `sync.run`,
  `verify.run`, and `pull.run` ops run one lifecycle verb; the `update.run`
  op chains one update step (`run_step/2`), which the client's plain runner
  and update screen drive in order.

  Every mutation runs under the target home's exclusive apply lock — the
  SAME `<state_root>/apply.lock` file the one-shot era used, so nothing
  outside the daemon can interleave on one home. In-daemon requests queue
  through `Workstation.Daemon.ApplyOrchestrator` (one orchestrated
  generation at a time for the whole daemon) BEFORE the file lock is taken,
  so two concurrent client ops queue instead of racing; the lock purpose
  strings are preserved verbatim from the one-shot driver, because they are
  operator-facing lock metadata. Lock scope stays PER STEP: each mutating
  step acquires and releases around itself, so a step failure never wedges
  the lock. `verify` and `pull` touch no mutable home state and stay
  lockless.

  Error vocabulary: every failure is `{:error, code, message}` — `"locked"`
  under contention, otherwise a step code carrying the verbatim engine
  message (the preconditions raise `ArgumentError` with actionable text).
  The wire layer maps the code to the client's exit-code contract.

  Options pass through to the core steps: `:home` (defaults to the daemon's
  pinned home), `:engine_root`, plus the test seams `:collector` (sandbox
  plan injection), `:installer`, `:bootstrap_run`, `:writer_identity`,
  and `:release_identity`.
  """

  alias Workstation.Core.{EngineState, Update}
  alias Workstation.Pipeline
  alias Workstation.Daemon.{ApplyOrchestrator, Events}

  # The update chain's canonical order (mirror of Workstation.Core.Update.steps/0,
  # pinned by a daemon test). A `steps` chain must be a non-empty order-
  # preserving subsequence — the chain is a RESUME primitive, not a
  # permutation surface.
  @canonical_steps ["pull", "bootstrap", "apply", "sync", "verify"]

  @doc "The canonical update-chain step order."
  @spec canonical_steps() :: [String.t()]
  def canonical_steps, do: @canonical_steps

  @doc """
  Validate a `steps` chain request: a non-empty, order-preserving subsequence
  of the canonical steps with no duplicates. Returns the steps or an
  `{:error, message}` worded for the wire's `invalid_params`.
  """
  @spec valid_chain?([term()]) :: {:ok, [String.t()]} | {:error, String.t()}
  def valid_chain?(steps) when is_list(steps) do
    if steps != [] and Enum.all?(steps, &is_binary/1) do
      canonical = @canonical_steps

      if Enum.uniq(steps) == steps and subsequence?(steps, canonical) do
        {:ok, steps}
      else
        {:error,
         "steps must be a non-empty subsequence of #{inspect(canonical)} in canonical order"}
      end
    else
      {:error, "steps must be a non-empty array of step names"}
    end
  end

  def valid_chain?(_other), do: {:error, "steps must be a non-empty array of step names"}

  defp subsequence?(steps, canonical), do: do_subsequence?(steps, canonical)

  defp do_subsequence?([], _rest), do: true

  defp do_subsequence?([step | steps], rest) do
    case Enum.drop_while(rest, &(&1 != step)) do
      [^step | new_rest] -> do_subsequence?(steps, new_rest)
      _other -> false
    end
  end

  ## verb surface (one lifecycle verb per op)

  @doc """
  Run an ordered update chain as ONE daemon-side op under the live event
  stream: `run.started`, `step.started`/`step.done` per step, `run.finished`.
  This is what the client's update verb drives since the streaming refactor —
  the daemon owns the chain, the client renders it; the one-in-flight op and
  the abort contract live on the session (`op.abort` honours the NEXT
  boundary — the only honest cancellation point for a lock-holding chain).

  Each step still runs through `run_step/2` (same locks, same codes, same
  handoff note contract), so the chain is the per-step op repeated. The
  result is one of:

    * `{:ok, record, refreshed?}` — the whole chain ran; `refreshed?` says
      whether any step refreshed the release (the wire layer's daemon-stop
      trigger for the verbs whose LAST step is a bootstrap);
    * `{:handoff, record, remaining}` — a bootstrap REFRESHED the release
      mid-chain: the daemon is about to stop itself (stale code), so the
      chain halts instead of running the remaining steps into a dying VM;
      the client re-spawns from the refreshed release and resumes them;
    * `{:aborted, next_step}` / `{:failed, code, message}` — the abort and
      error outcomes (both emit `run.finished`).

  The chain checks the abort flag before every step: an aborted chain
  finishes the step in flight (a cancelled mutation must not leave a half
  applied generation), skips the rest, and fails with the `aborted` code
  after emitting `run.finished{outcome: aborted}`.
  """
  @spec run_chain([String.t()], Events.op_ref(), keyword()) ::
          {:ok, map(), boolean()}
          | {:handoff, map(), [String.t()]}
          | {:error, String.t(), String.t()}
  def run_chain(steps, op_ref, opts \\ []) when is_list(steps) and is_binary(op_ref) and is_list(opts) do
    Events.emit(op_ref, "run.started", %{"op" => "update.run", "steps" => steps})

    outcome =
      chain_fold(steps, op_ref, opts, {:run, nil, false})

    case outcome do
      {:run, record, refreshed?} ->
        Events.emit(op_ref, "run.finished", %{"outcome" => "ok"})
        {:ok, record, refreshed?}

      {:handoff, record, remaining} ->
        Events.emit(op_ref, "run.finished", %{"outcome" => "handoff", "remaining" => remaining})
        {:handoff, record, remaining}

      {:aborted, _next_step} ->
        Events.emit(op_ref, "run.finished", %{"outcome" => "aborted"})
        {:error, "aborted", "update aborted at a step boundary"}

      {:failed, code, message} ->
        Events.emit(op_ref, "run.finished", %{"outcome" => "failed", "error" => "#{code}: #{message}"})
        {:error, code, message}
    end
  end

  # The per-step fold. State: {:run, last_record, refreshed?} | terminal. A successful bootstrap that REFRESHED the release halts the
  # chain in the `:handoff` state BEFORE the next step — the daemon stops
  # itself right after this op's reply flushes, and running further steps
  # into a stopping VM would kill a mutation mid-flight.
  defp chain_fold([], _op_ref, _opts, {:run, record, refreshed?}),
    do: {:run, record, refreshed?}

  defp chain_fold([step | rest], op_ref, opts, {:run, _last, refreshed?}) do
    if Events.aborted?(op_ref) do
      {:aborted, step}
    else
      case Events.step(op_ref, step, fn -> run_step(step, opts) end) do
        {:ok, record, _duration} ->
          # Only the bootstrap step refreshes (capabilities/lifecycle pins
          # @refresh_steps = ["bootstrap"]); a REFRESHED bootstrap halts the
          # chain BEFORE the next step — the daemon stops itself right after
          # this op's reply flushes, and running further steps into a
          # stopping VM would kill a mutation mid-flight.
          if record["release_refreshed"] == true do
            {:handoff, record, rest}
          else
            # The branch above already proved this step did not refresh, so
            # the carried flag is exactly the accumulated one.
            chain_fold(rest, op_ref, opts, {:run, record, refreshed?})
          end

        {:error, code, message, _duration} ->
          {:failed, code, message}
      end
    end
  end

  defp chain_fold(_rest, _op_ref, _opts, terminal), do: terminal

  @doc """
  Run one lifecycle verb. The lock purposes and error codes are the verb
  contracts recorded in docs/capabilities.md: `bootstrap` under
  `bootstrap.run` (code `bootstrap_failed`), `sync` under `sync.run`
  (code `sync_failed`), `verify` and `pull` lockless with their own codes.
  """
  @spec verb(String.t(), keyword()) :: {:ok, map()} | {:error, String.t(), String.t()}
  def verb(verb, opts \\ []) when is_binary(verb) and is_list(opts) do
    case verb do
      "bootstrap" -> with_lock("bootstrap.run", opts, fn -> bootstrap_locked(opts) end)
      "sync" -> with_lock("sync.run", opts, fn -> guarded(&sync_record/1, opts, "sync_failed") end)
      "verify" -> guarded(&verify_record/1, opts, "verify_failed")
      "pull" -> guarded(&pull_record/1, opts, "pull_failed")
      other -> {:error, "update_failed", "unknown lifecycle verb #{inspect(other)}"}
    end
  end

  @doc """
  Run one update-chain step (the `update.run` op body). Mutating steps
  (`bootstrap`, `apply`, `sync`) acquire the apply lock around themselves;
  `pull` and `verify` are lockless. The chain's lock purposes and error
  codes (`update_failed` for pull/sync/verify, `apply_failed` for apply)
  are the ones the plain runner's output contract was written against.
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

  ## step bodies

  defp pull_record(opts), do: elem(Update.Pull.run(core_opts(opts)), 1)

  defp sync_record(opts), do: elem(Update.Sync.run(core_opts(opts)), 1)

  defp verify_record(opts), do: elem(Update.Verify.run(core_opts(opts)), 1)

  defp bootstrap_locked(opts) do
    bootstrap_run = opts[:bootstrap_run] || (&Update.Bootstrap.run/1)

    with {:ok, record} <- guarded(fn _opts -> elem(bootstrap_run.(core_opts(opts)), 1) end, opts, "bootstrap_failed"),
         # Capture the WRITER's identity BEFORE the installer runs: the
         # refresh re-stamps the release, so a post-install read would
         # describe the NEW code — the refreshed process would then see its
         # own note as its own identity and hand off forever (the P0 in
         # 0fb69a4f). Tests inject :writer_identity to pin the pre/post
         # distinction a same-process read cannot express.
         writer_identity = Keyword.get(opts, :writer_identity, release_identity()) do
      case release_refresh(opts) do
        {:ok, refreshed?} ->
          case refresh_note(refreshed?, writer_identity, opts) do
            :ok ->
              # A refresh made a NEW on-disk release the chain must finish
              # under: report WHERE it landed so the client's re-exec
              # spawns the refreshed bin, not the stale root this process
              # booted from (the client's :code.root_dir() stays the old
              # release until the daemon restarts under the new one).
              record
              |> Map.put("release_refreshed", refreshed?)
              |> then(&if refreshed?, do: Map.put(&1, "release_root", installed_release_root(opts)), else: &1)
              |> then(&{:ok, &1})

            {:error, message} ->
              {:error, "bootstrap_failed", message}
          end

        {:error, output} ->
          {:error, "bootstrap_failed", "release refresh failed:\n#{output}"}
      end
    end
  end

  # The release handoff note (docs/capabilities.md, "release refresh and
  # handoff"): a REFRESHED bootstrap leaves a note naming the WRITER's
  # code identity, CAPTURED BEFORE THE INSTALLER RUNS (see
  # bootstrap_locked/1 — the refresh re-stamps the release, so a
  # post-install read would describe the NEW code). The writer is still
  # executing the OLD loaded code while the on-disk release just changed
  # under it; the client probes the note after every step and hands
  # the remaining chain to the new release. The note names identity, never
  # location: the runner derives the child bin from the release ROOT. The
  # parent clears the note itself when the handed-off child exits 0, and a
  # non-refreshing bootstrap REMOVES any leftover note — after a
  # refresh-free bootstrap, this process and the disk agree, so a stale
  # note from an earlier crashed handoff must not trigger a spurious
  # handoff later.
  defp refresh_note(false, _writer_identity, opts) do
    clear_update_handoff(opts)
    :ok
  end

  defp refresh_note(true, writer_identity, opts) do
    path = update_handoff_path(opts)

    case File.mkdir_p(Path.dirname(path)) do
      :ok -> write_handoff_note(path, writer_identity)
      {:error, reason} -> {:error, "cannot record the release handoff note: #{inspect(reason)}"}
    end
  end

  defp write_handoff_note(path, writer_identity) do
    note = Jason.encode!(%{"from_release" => writer_identity})

    case File.write(path, note) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot record the release handoff note: #{inspect(reason)}"}
    end
  end

  @doc """
  Probe the release handoff note left by a refreshed bootstrap step.

  Returns `{:ok, identity}` when the caller is still executing the CODE the
  note names — the on-disk release changed mid-run while this process keeps
  its old loaded modules, so the remaining update steps belong to the new
  release (the plain runner re-execs it with `--resume-from`). The note
  deliberately SURVIVES this return: if the re-exec dies, the next update
  run re-derives the same handoff instead of silently finishing the chain
  under stale code.

  Returns `{:ok, nil}` when there is nothing to hand off: no note, or the
  caller's code identity differs from the note's (the refreshed release
  itself — an in-place refresh REUSES the release root, so identity is the
  installer's stamp, never the path). The target consumes the note; the
  plain runner additionally clears it after a successful handed-off child.
  A malformed note is an error, never a silent continue: the note is engine
  state this module wrote.
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
            if from_release == Keyword.get(opts, :release_identity, release_identity()) do
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

  @doc """
  Remove the release handoff note unconditionally (idempotent, missing-ok).

  Called by the plain runner after a handed-off child exits 0 — parent
  success is `child exit 0 + note consumed` — and by every refresh-free
  bootstrap so a stale note cannot outlive the disk state it described.
  """
  @spec clear_update_handoff(keyword()) :: :ok
  def clear_update_handoff(opts \\ []) when is_list(opts) do
    File.rm(update_handoff_path(opts))
    :ok
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

  @doc """
  Identity of the CODE installed at a release root: the installer's
  .built-from stamp beside the root (first line), falling back to the root
  path itself when unstamped (dev/mix runs). Path identity alone is useless
  for in-place refreshes — the rebuilt release reuses the same root — so
  the live handoff looped forever re-handing off to itself (2026-10-05
  incident): identity must be the built code, not its location.
  """
  @spec release_identity(String.t()) :: String.t()
  def release_identity(root \\ :code.root_dir() |> to_string()) do
    case File.read(Path.join([root, ".built-from"])) do
      {:ok, stamp} -> stamp |> String.split("\n") |> hd() |> String.trim()
      {:error, _} -> root
    end
  end

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
      guarded(&apply_execute(plan, &1), opts, "apply_failed")
    else
      {:error, message} -> {:error, "apply_failed", message}
    end
  end

  defp apply_execute(plan, opts) do
    generation = Pipeline.execute(plan, %{"home" => home(opts)})
    %{"step" => "apply", "status" => "ok", "generation" => generation}
  end

  # The shared composition boundary (Pipeline.composed_plan/2), coded for this
  # surface: collection failures and engine preconditions both surface as a
  # plain `{:error, message}` the caller maps to its step code.
  defp composed_plan(opts) do
    case Pipeline.composed_plan(home(opts), opts[:collector]) do
      {:ok, plan} -> {:ok, plan}
      {:error, {:collect_failed, reason}} -> {:error, "plan collection failed: #{inspect(reason)}"}
      {:error, message} -> {:error, message}
    end
  end

  # Where the refresh installs: the same release root the launcher shim
  # execs from (docs/capabilities.md "release refresh and handoff"). The
  # handoff record reports it so the CLIENT re-execs the refreshed bin.
  defp installed_release_root(opts), do: Path.join([home(opts), ".local", "opt", "workstation"])

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

  defp core_opts(opts),
    do:
      opts
      |> Keyword.delete(:collector)
      |> Keyword.delete(:installer)
      |> Keyword.delete(:bootstrap_run)
      |> Keyword.delete(:writer_identity)
      |> Keyword.delete(:release_identity)

  # Daemon-side locking: requests QUEUE on the orchestrator mailbox (one
  # orchestrated generation for the whole daemon) before the file lock is
  # taken, so concurrent client ops serialize instead of failing with
  # `locked` against each other. The purpose strings are the one-shot
  # driver's, verbatim — they are operator-facing lock metadata.
  #
  # The orchestrator runs `fun` in ITS OWN process (the GenServer handling
  # the call), so an uncaught raise inside the fun would take down the
  # orchestrator — socket death for every session. The fun therefore folds
  # EVERY failure into a result tuple: the per-step `guarded/3` catches the
  # engine's ArgumentError contract, and the catch-all below is the last
  # line of defense for anything else.
  defp with_lock(purpose, opts, fun) do
    home = home(opts)

    # The lock lives inside the guarded state tree, and a fresh destination
    # has no tree yet: establish the write-side anchor before locking —
    # idempotent, final at 0700.
    EngineState.ensure_roots!(home)

    result =
      ApplyOrchestrator.with_lock(purpose, fn ->
        try do
          fun.()
        rescue
          error -> {:error, "lifecycle_failed", Exception.message(error)}
        end
      end)

    case result do
      {:error, {:locked, owner, _path}} -> {:error, "locked", "apply lock held by #{owner}"}
      other -> other
    end
  end

  # A step's engine failure surfaces verbatim: the message is the operator
  # interface (preconditions raise ArgumentError with actionable text), and
  # any engine raise folds to the step's error code, never a stacktrace.
  defp guarded(fun, opts, code) do
    {:ok, fun.(opts)}
  rescue
    error in [ArgumentError] -> {:error, code, Exception.message(error)}
  end
end
