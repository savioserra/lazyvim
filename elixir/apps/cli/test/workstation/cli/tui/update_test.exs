defmodule Workstation.CLI.TUI.UpdateTest do
  use ExUnit.Case, async: true

  import Workstation.CLITest.TUI

  alias TermUI.Command
  alias TermUI.Event
  alias TermUI.Frame
  alias Workstation.CLI.TUI.Theme
  alias Workstation.CLI.TUI.Update

  @destination "/home/test"

  defp screen_opts(extra) do
    [
      rows: 12,
      cols: 80,
      screen_opts:
        Keyword.merge(
          [
            destination: @destination,
            theme: Theme.base_colors(:dark),
            toast_ms: 60_000,
            executor: &Update.dry_run_executor/1,
            # Tests never touch a daemon: the availability check defaults
            # to the daemon op, so every screen run pins a silent verdict
            # unless the test asserts the indicator itself.
            check: fn -> {:ok, %{"status" => "up_to_date"}} end
          ],
          extra
        )
    ]
  end

  defp start_update(extra \\ []), do: start_screen!(Update, screen_opts(extra))

  # A chain executor that REPLAYS a recorded event list into the screen's
  # events sink, then settles with `outcome` — the deterministic-replay
  # contract: the screen's transitions come from the frames, never from
  # the executor driving steps itself.
  defp replay_executor(events, outcome) do
    fn %{"events" => events_sink} ->
      Enum.each(events, fn event -> events_sink.(event) end)
      outcome
    end
  end

  defp run_started(op_ref), do: %{"type" => "run.started", "op" => "update.run", "op_ref" => op_ref}

  defp step_started(step), do: %{"type" => "step.started", "step" => step}
  defp step_ok(step), do: %{"type" => "step.done", "step" => step, "ok" => true, "duration_ms" => 1}

  defp step_failed(step),
    do: %{"type" => "step.done", "step" => step, "ok" => false, "duration_ms" => 1}

  defp chain_finished(outcome), do: %{"type" => "run.finished", "outcome" => outcome}

  # Layout with rows: 12: box borders 1/12 (title + counters on 1, phase
  # buttonbar on 12), table header row 2, steps rows 3-7; the newest toast
  # box overlays rows 10-12.
  describe "step list run" do
    test "all steps pass and the success toast is token-guarded" do
      start_update()
      frame = latest_frame()

      assert frame |> Frame.row_text(1) =~ "update · #{@destination}"
      assert frame |> Frame.row_text(1) =~ "5 steps"
      assert frame |> Frame.row_text(1) =~ "abort on first failure"

      for {step, row} <- Enum.zip(Update.steps(), 3..7) do
        assert frame |> Frame.row_text(row) =~ step
        assert frame |> Frame.row_text(row) =~ "ok"
      end

      assert frame |> Frame.row_text(11) =~ "✓ Update completed"
      assert frame |> Frame.row_text(12) =~ "q quit"
    end

    test "abort on first failure: failing step marked, remaining skipped" do
      [pull, bootstrap, apply, sync, verify] = Update.steps()

      start_update(
        executor:
          replay_executor(
            [
              run_started("op-1"),
              step_started(pull),
              step_ok(pull),
              step_started(bootstrap),
              step_ok(bootstrap),
              step_started(apply),
              step_failed(apply),
              chain_finished("failed")
            ],
            {:error, "apply_refused: engine refused"}
          )
      )

      # Same async sink contract: chain_finished (row 7 skipped) is the
      # last event to render.
      frame =
        await_frame(fn frame ->
          Frame.row_text(frame, 7) =~ "skipped"
        end)

      assert frame |> Frame.row_text(3) =~ pull
      assert frame |> Frame.row_text(3) =~ "ok"
      assert frame |> Frame.row_text(4) =~ bootstrap
      assert frame |> Frame.row_text(4) =~ "ok"
      assert frame |> Frame.row_text(5) =~ apply
      assert frame |> Frame.row_text(5) =~ "failed"
      assert frame |> Frame.row_text(6) =~ sync
      assert frame |> Frame.row_text(6) =~ "skipped"
      assert frame |> Frame.row_text(7) =~ verify
      assert frame |> Frame.row_text(7) =~ "skipped"

      assert frame |> Frame.row_text(11) =~ "Update failed: apply_refused"
    end

    test "an aborted chain renders the un-settled steps skipped" do
      [pull, _bootstrap, _apply, sync, verify] = Update.steps()

      start_update(
        executor:
          replay_executor(
            [
              run_started("op-2"),
              step_started(pull),
              step_ok(pull),
              chain_finished("aborted")
            ],
            {:error, "aborted: update aborted at a step boundary"}
          )
      )

      # The chain events land through the screen's async events sink —
      # wait for the LAST event (chain_finished flipping sync/verify to
      # skipped) so every row assert below reads a settled frame.
      frame =
        await_frame(fn frame ->
          Frame.row_text(frame, 6) =~ "skipped"
        end)

      assert frame |> Frame.row_text(3) =~ pull
      assert frame |> Frame.row_text(3) =~ "ok"
      assert frame |> Frame.row_text(6) =~ sync
      assert frame |> Frame.row_text(6) =~ "skipped"
      assert frame |> Frame.row_text(7) =~ verify
      assert frame |> Frame.row_text(7) =~ "skipped"
    end
  end

  describe "availability indicator (supervisor-directed scope)" do
    # The completion toast overlaps the footer's right side while visible;
    # a short toast plus a forced redraw asserts the PERSISTENT indicator
    # the way an operator sees it after the toast expires.
    test "a behind verdict surfaces the accent footer and the [u] affordance" do
      runtime =
        start_update(
          toast_ms: 30,
          check: fn -> {:ok, %{"status" => "behind", "local" => "abc1234", "remote" => "def5678"}} end
        )

      # Consume the run frames, let the toast expire, then force a
      # deterministic redraw and assert the settled footer.
      _early = latest_frame()
      Process.sleep(200)
      send_event(runtime, Event.resize(80, 12))
      frame = latest_frame()

      assert frame |> Frame.row_text(12) =~
               "↑ update available (abc1234 → def5678) — [u] update"
    end

    test "up_to_date, unknown and errors stay silent" do
      for verdict <- [
            {:ok, %{"status" => "up_to_date"}},
            {:ok, %{"status" => "unknown", "reason" => "offline"}},
            {:error, "no daemon is running"}
          ] do
        runtime = start_update(check: fn -> verdict end, toast_ms: 30)
        _early = latest_frame()
        Process.sleep(200)
        send_event(runtime, Event.resize(80, 12))
        frame = latest_frame()
        refute frame |> Frame.row_text(12) =~ "update available"
      end
    end
  end

  describe "pure update/2 contract" do
    defp state do
      {state, _chain_start} =
        Update.init(
          destination: @destination,
          theme: Theme.base_colors(:dark),
          dimensions: {64, 12},
          toast_ms: 1_000,
          # The pure contract tests need a succeeding executor: the default
          # is the daemon-orchestrated path, which refuses without a daemon.
          executor: &Update.dry_run_executor/1,
          check: fn -> {:ok, %{"status" => "up_to_date"}} end
        )

      state
    end

    test "init starts the chain and the check as async effects" do
      {init_state, commands} =
        Update.init(
          destination: @destination,
          theme: Theme.base_colors(:dark),
          dimensions: {64, 12},
          toast_ms: 1_000,
          check: fn -> {:ok, %{"status" => "up_to_date"}} end
        )

      assert %{run: %{ref: _ref, op_ref: nil}} = init_state
      assert [%Command{kind: :async}, %Command{kind: :async}] = commands
    end

    test "step transitions resolve through update/2 from event frames" do
      state = state()
      %{ref: ref} = state.run

      # run.started captures the daemon's stream token (what abort rides).
      state = Update.update({:update_event, ref, run_started("op-9")}, state)
      assert %{run: %{op_ref: "op-9"}} = state

      state = Update.update({:update_event, ref, step_started("pull")}, state)
      assert step_status(state, "pull") == "running"

      state = Update.update({:update_event, ref, step_ok("pull")}, state)
      assert step_status(state, "pull") == "ok"
      assert step_status(state, "bootstrap") == "pending"

      state = Update.update({:update_event, ref, step_ok("bootstrap")}, state)
      assert step_status(state, "bootstrap") == "ok"
    end

    test "chain_done settles the run with the token-guarded toast" do
      state = state()
      %{ref: ref} = state.run

      state = Update.update({:update_event, ref, run_started("op-9")}, state)

      state =
        Enum.reduce(Update.steps(), state, fn step, state ->
          Update.update({:update_event, ref, step_ok(step)}, state)
        end)

      {state, commands} = Update.update({:chain_done, ref, :ok}, state)

      assert state.phase == :done
      assert state.run == nil
      # The completion toast expiry timer plus the post-completion
      # availability check.
      assert [%Command{kind: :timer}, %Command{kind: :async}] = commands
      assert [%{id: :update_result, type: :success}] = state.toasts.toasts
    end

    test "failure marks the step failed, the rest skipped, and stops the chain" do
      state = state()
      %{ref: ref} = state.run

      state = Update.update({:update_event, ref, run_started("op-9")}, state)

      state =
        Enum.reduce(["pull", "bootstrap", "apply"], state, fn step, state ->
          Update.update({:update_event, ref, step_ok(step)}, state)
        end)

      state = Update.update({:update_event, ref, step_failed("sync")}, state)
      {state, commands} = Update.update({:chain_done, ref, {:error, "no space left"}}, state)

      assert step_status(state, "sync") == "failed"
      assert step_status(state, "verify") == "skipped"
      assert state.phase == :done
      assert [%Command{kind: :timer}] = commands
      assert [%{id: :update_result, type: :error}] = state.toasts.toasts
    end

    test "check_done folds only behind verdicts into the hint" do
      state = state()

      state =
        Update.update(
          {:check_done, {:ok, %{"status" => "behind", "local" => "abc1234", "remote" => "def5678"}}},
          state
        )

      assert state.update_hint == %{"local" => "abc1234", "remote" => "def5678"}

      state = Update.update({:check_done, {:ok, %{"status" => "up_to_date"}}}, state)
      assert state.update_hint == nil

      state = Update.update({:check_done, {:error, "no daemon"}}, state)
      assert state.update_hint == nil
    end

    test "u re-runs the flow only from a finished screen with a hint" do
      state = state()
      # While running, u is ignored.
      assert %Update{} = state = Update.update({:text, "u"}, state)
      assert state.phase == :running

      ref = state.run.ref
      state = Update.update({:update_event, ref, run_started("op-9")}, state)

      state =
        Enum.reduce(Update.steps(), state, fn step, state ->
          Update.update({:update_event, ref, step_ok(step)}, state)
        end)

      {state, _commands} = Update.update({:chain_done, ref, :ok}, state)

      # Without a surfaced verdict, u is still ignored.
      assert %Update{phase: :done} = state = Update.update({:text, "u"}, state)

      state =
        Update.update(
          {:check_done, {:ok, %{"status" => "behind", "local" => "abc1234", "remote" => "def5678"}}},
          state
        )

      # With the indicator showing, u resets the rows and launches a fresh
      # chain (a new run token — the old chain's events can never leak in).
      {state, [%Command{kind: :async}]} = Update.update({:text, "u"}, state)
      assert state.phase == :running
      assert Enum.all?(state.steps, &(&1["status"] == "pending"))
      assert state.run.ref != ref
    end

    test "x forwards op.abort only once the stream token is known" do
      state = state()

      # No op_ref yet: x is inert.
      assert %Update{} = state = Update.update({:text, "x"}, state)
      assert state.phase == :running

      ref = state.run.ref
      state = Update.update({:update_event, ref, run_started("op-42")}, state)

      {state, [%Command{kind: :async}]} = Update.update({:text, "x"}, state)
      assert state.phase == :running
    end

    test "stale chain messages are dropped" do
      state = state()

      stale_event = %{"type" => "step.started", "step" => "pull"}

      assert %Update{} = state = Update.update({:update_event, make_ref(), stale_event}, state)
      assert step_status(state, "pull") == "pending"

      assert %Update{} = state = Update.update({:chain_done, make_ref(), :ok}, state)
      assert state.phase == :running
    end

    test "q is Command.shutdown(:normal) — a detach, the daemon keeps running" do
      assert {state, [%Command{kind: :shutdown, value: :normal}]} =
               Update.update({:text, "q"}, state())

      assert %Update{} = state
    end

    defp step_status(state, id) do
      Enum.find_value(state.steps, fn step -> step["id"] == id && step["status"] end)
    end
  end
end
