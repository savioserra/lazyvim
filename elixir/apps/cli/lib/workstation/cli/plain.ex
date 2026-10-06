defmodule Workstation.CLI.Plain do
  @moduledoc """
  The headless runner for the apply/update front door (the `--headless`
  contract): the same run the TUI screens render, emitted line-oriented on
  stdout, with zero terminal interaction.

  There is no silent degradation: this runner runs ONLY when the operator
  passed `--headless` (or the caller injected this executor seam directly,
  as tests do). The Router refuses a non-interactive `apply`/`update`
  without `--headless` before any executor runs, so a piped invocation can
  never fall back to plain silently.

  Two invariants come from the wire contract: this is never an alternate
  machine schema (the hard-cut Output schemas remain the only machine
  contract — these lines are human progress, not wire), and there is never
  an interactive prompt on a pipe.

  Exit codes stay the CLI table (Workstation.CLI.Router): 0 ok, 2 usage,
  4 when the executor reports a failure. Update aborts on the first failing
  lifecycle step (docs/capabilities.md) and reports the remaining steps as
  skipped.

  The update chain is ONE daemon op (`update.run` with the full step
  sub-chain): the daemon owns the locks, the steps, and the handoff note;
  this runner renders the daemon's event stream as lines (the familiar
  `[1/5] pull ok` shape, now event-driven — never self-driven) and carries
  the release handoff the daemon REPORTS: a mid-chain refresh halts the
  daemon-side chain, the result arrives with `handed_off: true` plus the
  un-run steps, and this runner re-execs the refreshed release with
  `--resume-from`, forwarding its output and exit code, so the remaining
  steps execute under the freshly built engine instead of the stale code
  this process loaded at boot. The BEAM has no exec(2), so the handoff is
  a supervised child whose status becomes this run's exit status — the
  observable two-phase contract is one command, one exit code.
  """

  alias Workstation.Daemon.Lifecycle
  alias Workstation.CLI.TUI.Apply
  alias Workstation.CLI.TUI.Executor
  alias Workstation.CLI.TUI.Update

  @doc """
  Run the headless runner for `:apply` or `:update`.

  Options mirror the TUI screens: `:destination`, `:plan` (apply), and
  `:executor` (same callback contract). Defaults are the production
  executors (`Workstation.CLI.TUI.Executor`, the socket client path);
  pure stand-ins remain injectable for tests.
  """
  @spec run(:apply | :update, keyword()) :: :ok
  def run(command, opts) when command in [:apply, :update] do
    destination = Keyword.fetch!(opts, :destination)

    case command do
      :apply ->
        run_apply(destination, Keyword.fetch!(opts, :plan), Keyword.get(opts, :executor, &Executor.apply_executor/1))

      :update ->
        run_update(destination, Keyword.get(opts, :executor, &Executor.update_executor/1), opts)
    end
  end

  def run(command, _opts), do: fail(2, "error: unknown command #{inspect(command)}")

  defp run_apply(destination, plan, executor) do
    entries = Apply.entries_from_plan(plan)
    generation = Map.fetch!(plan, "generation")

    IO.puts("Apply to #{destination} (generation #{generation})")
    Enum.each(entries, &IO.puts("  #{&1["operation"]}  #{&1["target"]}"))

    case executor.(%{"generation" => generation, "entries" => entries}) do
      :ok ->
        # Same 10-tick shape as the TUI Progress: one contract, two renderers.
        Enum.each(1..10, fn tick ->
          IO.puts("  applying #{tick * div(100, 10)}%")
        end)

        IO.puts("Applied generation #{generation}")
        :ok

      {:error, reason} ->
        fail(4, "error: apply failed: #{reason}")
    end
  end

  defp run_update(destination, executor, opts) do
    steps = resume_steps(opts[:resume_from])
    total = length(Update.steps())

    IO.puts("Update #{destination} (#{total} steps)")

    # The daemon owns the chain and the handoff note; this process renders
    # its event stream and tracks the settled steps so a failure (or an
    # abort) reports the UNRUN steps as skipped with original numbering.
    {:ok, seen} = Agent.start_link(fn -> %{ok: MapSet.new(), failed: nil} end)

    on_event = fn event ->
      render_event(event, steps, total)
      track_event(seen, event)
    end

    request = %{"steps" => Enum.map(steps, &elem(&1, 0)), "events" => on_event}

    case executor.(request) do
      {:ok, %{"handed_off" => true} = record} ->
        case handoff_steps(record["remaining_steps"], steps) do
          [] ->
            # Nothing left to hand off (the chain ended on the refresher):
            # the empty --resume-from child was the live 2026-10-05
            # incident's exit-2 trigger — finish normally instead.
            IO.puts("Updated")
            :ok

          remaining ->
            handoff(remaining, total, record, opts)
        end

      {:ok, _record} ->
        IO.puts("Updated")
        :ok

      {:error, {:daemon_died, message}} ->
        fail(4, "error: the daemon died mid-update: #{message}")

      {:error, {:daemon_unavailable, message}} ->
        fail(4, "error: #{message}")

      {:error, {"aborted", _message}} ->
        skipped_tail(seen, steps, total)
        fail(4, "error: update aborted at a step boundary")

      {:error, {_code, _message}} ->
        skipped_tail(seen, steps, total)

        case Agent.get(seen, & &1)[:failed] do
          {step, detail} -> fail(4, "error: update failed at #{step}: #{detail}")
          nil -> fail(4, "error: update failed")
        end
    end
  end

  # The headless half of the research contract: the SAME event stream the
  # TUI renders, as lines. `step.done` keeps the familiar `[1/5] pull ok`
  # shape (now daemon-driven); `run.log` lines render under the `|` prefix;
  # `step.started`/`run.started`/`run.finished` render nothing (the chain
  # banner and the tail already say it).
  defp render_event(%{"type" => "step.done", "step" => step, "ok" => true} = _event, steps, total) do
    IO.puts("  [#{step_index(step, steps)}/#{total}] #{step} ok")
  end

  defp render_event(%{"type" => "step.done", "step" => step, "ok" => false, "detail" => detail}, steps, total) do
    IO.puts("  [#{step_index(step, steps)}/#{total}] #{step} failed: #{detail}")
  end

  defp render_event(%{"type" => "run.log", "line" => line}, _steps, _total) do
    IO.puts("  | #{line}")
  end

  defp render_event(_event, _steps, _total), do: :ok

  defp track_event(seen, %{"type" => "step.done", "step" => step, "ok" => true}),
    do: Agent.update(seen, fn state -> %{state | ok: MapSet.put(state.ok, step)} end)

  defp track_event(seen, %{"type" => "step.done", "step" => step, "ok" => false, "detail" => detail}),
    do: Agent.update(seen, fn state -> %{state | failed: {step, detail}} end)

  defp track_event(_seen, _event), do: :ok

  defp step_index(step, steps) do
    {_, index} = Enum.find(steps, fn {name, _} -> name == step end)
    index
  end

  # Everything the daemon did not settle is reported skipped, in chain
  # order (the daemon stops at the first failure or abort boundary).
  defp skipped_tail(seen, steps, total) do
    done = Agent.get(seen, & &1)[:ok]

    steps
    |> Enum.reject(fn {step, _} -> MapSet.member?(done, step) end)
    |> Enum.each(fn {step, index} -> IO.puts("  [#{index}/#{total}] #{step} skipped") end)
  end

  # --resume-from (the release handoff's re-exec contract): a comma-
  # separated sub-chain of the lifecycle, validated against the real steps
  # and run with their ORIGINAL chain numbering so the two-phase run reads
  # as one sequence. Unknown, empty, or duplicate names are usage errors.
  defp resume_steps(nil), do: Update.steps() |> Enum.with_index(1)

  defp resume_steps(csv) do
    names = String.split(csv, ",", trim: true)
    known = Update.steps()

    cond do
      names == [] ->
        fail(2, "error: --resume-from requires a comma-separated step list")

      names != Enum.uniq(names) ->
        fail(2, "error: --resume-from lists a step twice: #{csv}")

      true ->
        Enum.each(names, fn name ->
          unless name in known do
            fail(2, "error: --resume-from: unknown update step #{inspect(name)} (known: #{Enum.join(known, ", ")})")
          end
        end)

        known
        |> Enum.with_index(1)
        |> Enum.filter(fn {step, _index} -> step in names end)
    end
  end

  # Map the daemon's remaining-steps list back onto this run's chain
  # numbering: the re-exec child reads `[n/total] step handed off` lines
  # with the SAME indices the parent printed, so the two-phase run reads
  # as one sequence.
  defp handoff_steps(remaining, steps) when is_list(remaining) do
    Enum.filter(steps, fn {step, _index} -> step in remaining end)
  end

  # The handoff re-exec: spawn `<release root>/bin/workstation` with the
  # remaining steps, forwarding output and exit status (the BEAM has no
  # exec(2); the observable contract is one command, one exit code). The
  # bin is derived from the release ROOT, never the identity value —
  # identity is the built-code stamp, an opaque token that may carry a
  # path fallback but is not guaranteed to be a path; spawning it verbatim
  # raised a raw :enoent ErlangError on the live host (the P0 in
  # 0fb69a4f). The child inherits this process' environment — including
  # any WORKSTATION_HOME bracket — because it re-derives engine state the
  # same way the parent did. Parent success = child exit 0 + note
  # consumed: the parent clears the note itself (a crashed re-exec must
  # leave it for re-derivation), and a nonzero child status — including
  # exit 2 argv validation, which is never retried — fails the run with
  # the child's status echoed. A missing or non-executable bin fails
  # cleanly (exit 4) instead of a raw ErlangError.
  defp handoff(remaining, total, record, opts) do
    # The daemon REPORTS the refreshed release root (it knows where its
    # installer landed); the client root is the stale release this process
    # booted from and only a fallback. Tests pin it via the
    # :handoff_release_root seam.
    root =
      Keyword.get(opts, :handoff_release_root) || record["release_root"] || to_string(:code.root_dir())

    bin = Path.join([root, "bin", "workstation"])

    Enum.each(remaining, fn {step, index} ->
      IO.puts("  [#{index}/#{total}] #{step} handed off to the refreshed release")
    end)

    IO.puts("Update handed off to #{root}")

    unless executable?(bin) do
      fail(4, "error: the handed-off release has no executable workstation binary at #{bin}")
    end
    argv = ["update", "--headless", "--resume-from", Enum.map_join(remaining, ",", fn {step, _} -> step end)]

    case System.cmd(bin, argv, into: IO.stream(:stdio, :line), stderr_to_stdout: true) do
      {_output, 0} ->
        # The remaining chain completed under the new release; the child
        # printed its own chain lines and final banner. The note is
        # consumed exactly once: cleared here so no later run re-derives
        # a handoff that already finished.
        clear = Keyword.get(opts, :handoff_clear, &Lifecycle.clear_update_handoff/1)
        clear.(opts)
        :ok

      {_output, code} ->
        fail(4, "error: update failed under the handed-off release (exit #{code})")
    end
  end

  # The launcher-shape guard: the spawn target must be a regular file with
  # any execute bit — System.cmd on a missing bin raises a raw :enoent
  # ErlangError (exit 1, stranded handoff note), which the two-phase
  # contract reports as a controlled engine failure instead.
  defp executable?(bin) do
    case File.stat(bin) do
      {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _other -> false
    end
  end

  # Mirrors Router's exit plumbing: {:shutdown, code} keeps Mix/EScript from
  # printing a stacktrace for a controlled failure.
  defp fail(code, message) do
    IO.puts(:stderr, message)
    exit({:shutdown, code})
  end
end
