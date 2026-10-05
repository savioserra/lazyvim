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
  """

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
        run_update(destination, Keyword.get(opts, :executor, &Executor.update_executor/1))
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

  defp run_update(destination, executor) do
    steps = Update.steps()
    total = length(steps)

    IO.puts("Update #{destination} (#{total} steps)")

    Enum.reduce_while(Enum.with_index(steps, 1), :ok, fn {step, index}, :ok ->
      case executor.(%{"step" => step}) do
        :ok ->
          IO.puts("  [#{index}/#{total}] #{step} ok")
          {:cont, :ok}

        {:error, reason} ->
          IO.puts("  [#{index}/#{total}] #{step} failed: #{reason}")

          remaining = Enum.drop(steps, index)

          remaining
          |> Enum.with_index(index + 1)
          |> Enum.each(fn {skipped, n} -> IO.puts("  [#{n}/#{total}] #{skipped} skipped") end)

          {:halt, {:error, {step, reason}}}
      end
    end)
    |> case do
      :ok ->
        IO.puts("Updated")
        :ok

      {:error, {step, reason}} ->
        fail(4, "error: update failed at #{step}: #{reason}")
    end
  end

  # Mirrors Router's exit plumbing: {:shutdown, code} keeps Mix/EScript from
  # printing a stacktrace for a controlled failure.
  defp fail(code, message) do
    IO.puts(:stderr, message)
    exit({:shutdown, code})
  end
end
