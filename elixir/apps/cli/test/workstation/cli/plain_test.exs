defmodule Workstation.CLI.PlainTest do
  use ExUnit.Case, async: true

  alias Workstation.CLI.Plain
  alias Workstation.CLI.TUI.Apply
  alias Workstation.CLI.TUI.Update

  @destination "/home/test"

  @plan %{
    "schema" => "workstation.plan.v1",
    "generation" => "gen-1",
    "plan" => %{
      "entries" => [
        %{"name" => "dot_bashrc", "operation" => "file", "target" => ".bashrc"},
        %{"name" => "dot_tmux.conf", "operation" => "file", "target" => ".tmux.conf"}
      ]
    }
  }

  # Plain.run exits with {:shutdown, code}; run it off the test process so
  # the exit becomes a value, and capture stdout and stderr together since
  # refusals/failures are reported on stderr.
  defp run_plain(command, opts) do
    me = self()

    {pid, ref} =
      spawn_monitor(fn ->
        stderr =
          ExUnit.CaptureIO.capture_io(:stderr, fn ->
            stdout =
              ExUnit.CaptureIO.capture_io(fn ->
                result =
                  try do
                    Plain.run(command, opts)
                    :ok
                  catch
                    :exit, {:shutdown, code} -> {:shutdown, code}
                  end

                send(me, {:plain_result, result})
              end)

            send(me, {:plain_stdout, stdout})
          end)

        send(me, {:plain_stderr, stderr})
      end)

    result =
      receive do
        {:plain_result, result} -> result
        {:DOWN, ^ref, :process, ^pid, reason} -> {:down, reason}
      after
        5_000 -> flunk("plain run did not finish")
      end

    stdout =
      receive do
        {:plain_stdout, stdout} -> stdout
      after
        1_000 -> ""
      end

    stderr =
      receive do
        {:plain_stderr, stderr} -> stderr
      after
        1_000 -> ""
      end

    Process.demonitor(ref, [:flush])
    {result, stdout <> stderr}
  end

  test "without --yes the run refuses with the usage exit code and never prompts" do
    assert {{:shutdown, 2}, output} = run_plain(:apply, destination: @destination, plan: @plan)
    assert output =~ "--yes"
    assert output =~ "no prompt is offered on a pipe"

    assert {{:shutdown, 2}, _output} = run_plain(:update, destination: @destination)
  end

  test "apply prints the plan, the tick progress, and the result" do
    {:ok, output} =
      run_plain(:apply,
        destination: @destination,
        plan: @plan,
        yes: true,
        executor: fn %{"generation" => generation, "entries" => entries} ->
          # Request-map contract (b8): the executor sees exactly what the
          # daemon op schema validates.
          assert generation == "gen-1"
          assert length(entries) == 2
          :ok
        end
      )

    assert output =~ "Apply to #{@destination} (generation gen-1)"
    assert output =~ "file  .bashrc"
    assert output =~ "file  .tmux.conf"
    assert output =~ "applying 10%"
    assert output =~ "applying 100%"
    assert output =~ "Applied generation gen-1"
  end

  test "apply executor failure exits 4 and never prints a success line" do
    {{:shutdown, 4}, output} =
      run_plain(:apply,
        destination: @destination,
        plan: @plan,
        yes: true,
        executor: fn %{"generation" => _gen, "entries" => _entries} -> {:error, "engine refused"} end
      )

    assert output =~ "apply failed: engine refused"
    refute output =~ "Applied generation"
  end

  test "update prints every step and completes" do
    {:ok, output} =
      run_plain(:update,
        destination: @destination,
        yes: true,
        executor: &Update.dry_run_executor/1
      )

    for step <- Update.steps() do
      assert output =~ step
      assert output =~ "ok"
    end

    assert output =~ "Updated"
  end

  test "update aborts on first failure, marks the rest skipped, exits 4" do
    {{:shutdown, 4}, output} =
      run_plain(:update,
        destination: @destination,
        yes: true,
        executor: fn
          %{"step" => "sync"} -> {:error, "no space left"}
          %{} -> :ok
        end
      )

    assert output =~ "[3/5] apply ok"
    assert output =~ "[4/5] sync failed: no space left"
    assert output =~ "[5/5] verify skipped"
    refute output =~ "Updated"
  end

  test "unknown commands exit 2" do
    assert {{:shutdown, 2}, output} = run_plain(:destroy, destination: @destination)
    assert output =~ "unknown command"
  end

  test "the default executor is the daemon-orchestrated path, which fails closed" do
    # One spelling per concept: plain fallback and screens share the executor
    # seam. The default is now the production executor (b8 wiring); with no
    # daemon serving the destination it must refuse, never "succeed".
    assert {{:shutdown, 4}, output} =
             run_plain(:apply, destination: @destination, plan: @plan, yes: true)

    assert output =~ "apply failed"
    # The pure stand-ins stay injectable and always succeed (tests only).
    assert Apply.dry_run_executor(%{"entries" => []}) == :ok
    assert Update.dry_run_executor(%{"step" => "pull"}) == :ok
  end
end
