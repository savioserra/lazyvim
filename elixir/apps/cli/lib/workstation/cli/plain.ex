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

  The update chain carries the release handoff (docs/capabilities.md,
  "release refresh and handoff"): after every step the runner probes
  `Workstation.CLI.Engine.update_handoff/1`; when a refreshed bootstrap
  left its handoff note the remaining steps are printed as handed off and
  the runner runs the NEW release with `--resume-from`, forwarding its
  output and exit code, so apply/sync/verify execute under the freshly
  built engine instead of the stale code this process loaded at boot. The
  BEAM has no exec(2), so the handoff is a supervised child whose status
  becomes this run's exit status — the observable two-phase contract is
  one command, one exit code.
  """

  alias Workstation.CLI.Engine
  alias Workstation.CLI.TUI.Apply
  alias Workstation.CLI.TUI.Executor
  alias Workstation.CLI.TUI.Update

  @doc """
  Run the headless runner for `:apply` or `:update`.

  Options mirror the TUI screens: `:destination`, `:plan` (apply), and
  `:executor` (same callback contract). Defaults are the production
  executors (`Workstation.CLI.TUI.Executor`, the in-process engine path);
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

    # The CALLER's code identity, captured ONCE at chain start — before
    # the bootstrap step can re-stamp the release mid-run. A fresh read
    # after the refresh would describe the NEW code, not the code THIS
    # process executes (the P0 in 0fb69a4f: a post-refresh note then
    # matched a post-refresh probe and the chain handed off forever). The
    # default probe (Engine.update_handoff/1) consumes it via the
    # :release_identity seam; injected test probes just ignore it.
    identity = Keyword.get(opts, :release_identity) || Engine.release_identity()
    opts = Keyword.put(opts, :release_identity, identity)
    probe = Keyword.get(opts, :handoff_probe, &Engine.update_handoff/1)
    total = length(Update.steps())

    IO.puts("Update #{destination} (#{total} steps)")

    steps
    |> Enum.reduce_while(:ok, fn {step, index}, :ok ->
      case executor.(%{"step" => step}) do
        :ok ->
          IO.puts("  [#{index}/#{total}] #{step} ok")
          after_step(probe, opts, steps, index, total)

        {:error, reason} ->
          IO.puts("  [#{index}/#{total}] #{step} failed: #{reason}")

          steps
          |> Enum.drop_while(fn {_s, i} -> i <= index end)
          |> Enum.each(fn {skipped, n} -> IO.puts("  [#{n}/#{total}] #{skipped} skipped") end)

          {:halt, {:error, {step, reason}}}
      end
    end)
    |> case do
      :ok ->
        IO.puts("Updated")
        :ok

      {:handoff, remaining} ->
        handoff(remaining, total, opts)

      {:error, {step, reason}} ->
        fail(4, "error: update failed at #{step}: #{reason}")
    end
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

  # The handoff probe runs after EVERY step and receives this run's opts
  # (the caller identity is threaded on :release_identity — the default
  # Engine.update_handoff/1 probe consumes it; injected probes share the
  # same `(opts)` contract as `:executor`): a note can only exist when a
  # bootstrap refreshed the release (or an earlier run crashed between the
  # refresh and its exec), and in both cases the remaining chain belongs to
  # the new release. A no-note probe is one file read that misses. When the
  # just-completed step was the LAST one there is nothing left to hand off
  # (the empty --resume-from child was the live 2026-10-05 incident's exit-2
  # trigger), so the run finishes normally and the parent clears the note.
  # The probe is injectable (`:handoff_probe`) with the same seam contract
  # as `:executor`.
  defp after_step(probe, opts, steps, index, total) do
    case probe.(opts) do
      {:ok, nil} ->
        {:cont, :ok}

      {:ok, _release} ->
        remaining = Enum.drop_while(steps, fn {_s, i} -> i <= index end)

        if remaining == [] do
          {:cont, :ok}
        else
          {:halt, {:handoff, remaining}}
        end

      {:error, message} ->
        IO.puts("  [#{index}/#{total}] handoff failed: #{message}")
        {:halt, {:error, {"handoff", message}}}
    end
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
  defp handoff(remaining, total, opts) do
    root = Keyword.get(opts, :handoff_release_root) || to_string(:code.root_dir())
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
        clear = Keyword.get(opts, :handoff_clear, &Engine.clear_update_handoff/1)
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
