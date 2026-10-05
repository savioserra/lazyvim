defmodule Workstation.CLI.TUI.UpdateTest do
  use ExUnit.Case, async: true

  import Workstation.CLITest.TUI

  alias TermUI.Command
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
            executor: &Update.dry_run_executor/1
          ],
          extra
        )
    ]
  end

  defp start_update(extra \\ []), do: start_screen!(Update, screen_opts(extra))

  # Layout with rows: 12: header 1-2, table header row 3, steps rows 4-8,
  # footer 12; newest toast box rows 10-12.
  describe "step list run" do
    test "all steps pass and the success toast is token-guarded" do
      start_update()
      frame = latest_frame()

      assert frame |> Frame.row_text(1) =~ "workstation update"
      assert frame |> Frame.row_text(1) =~ @destination
      assert frame |> Frame.row_text(2) =~ "5 steps · abort on first failure"

      for {step, row} <- Enum.zip(Update.steps(), 4..8) do
        assert frame |> Frame.row_text(row) =~ step
        assert frame |> Frame.row_text(row) =~ "ok"
      end

      assert frame |> Frame.row_text(11) =~ "✓ Update completed"
      assert frame |> Frame.row_text(12) =~ "q quit"
    end

    test "abort on first failure: failing step marked, remaining skipped" do
      start_update(
        executor: fn
          %{"step" => "apply"} -> {:error, "engine refused"}
          %{} -> :ok
        end
      )

      frame = latest_frame()

      assert frame |> Frame.row_text(4) =~ "pull"
      assert frame |> Frame.row_text(4) =~ "ok"
      assert frame |> Frame.row_text(5) =~ "bootstrap"
      assert frame |> Frame.row_text(5) =~ "ok"
      assert frame |> Frame.row_text(6) =~ "apply"
      assert frame |> Frame.row_text(6) =~ "failed"
      assert frame |> Frame.row_text(7) =~ "sync"
      assert frame |> Frame.row_text(7) =~ "skipped"
      assert frame |> Frame.row_text(8) =~ "verify"
      assert frame |> Frame.row_text(8) =~ "skipped"

      assert frame |> Frame.row_text(11) =~ "× Update failed: engine refused"
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
          executor: &Update.dry_run_executor/1
        )

      state
    end

    test "init starts the chain: init returns a chain-link command" do
      {init_state, commands} =
        Update.init(
          destination: @destination,
          theme: Theme.base_colors(:dark),
          dimensions: {64, 12},
          toast_ms: 1_000
        )

      assert %{run: %{ref: ref}} = init_state
      assert [%Command{kind: :message, value: {:run_step, ^ref}}] = commands
    end

    test "each step resolves through update/2 as a chain of self-messages" do
      state = state()
      %{ref: ref} = state.run

      {state, [%Command{kind: :message, value: {:run_step, ^ref}}]} =
        Update.update({:run_step, ref}, state)

      assert step_status(state, "pull") == "ok"
      assert step_status(state, "bootstrap") == "pending"

      {state, [%Command{kind: :message, value: {:run_step, ^ref}}]} =
        Update.update({:run_step, ref}, state)

      assert step_status(state, "bootstrap") == "ok"

      # apply and sync keep the chain alive; the fifth step (verify) closes
      # the run into the token-guarded toast.
      {state, [_chain]} = Update.update({:run_step, ref}, state)
      {state, [_chain]} = Update.update({:run_step, ref}, state)
      {state, commands} = Update.update({:run_step, ref}, state)
      assert state.phase == :done
      assert [%Command{kind: :timer}] = commands
      assert [%{id: :update_result, type: :success}] = state.toasts.toasts
    end

    test "failure marks the step failed, the rest skipped, and stops the chain" do
      {state, _commands} =
        Update.init(
          destination: @destination,
          theme: Theme.base_colors(:dark),
          dimensions: {64, 12},
          toast_ms: 1_000,
          executor: fn
            %{"step" => "sync"} -> {:error, "no space left"}
            %{} -> :ok
          end
        )

      %{ref: ref} = state.run

      # pull, bootstrap, apply succeed; sync fails; verify is skipped.
      {state, _} = Update.update({:run_step, ref}, state)
      {state, _} = Update.update({:run_step, ref}, state)
      {state, _} = Update.update({:run_step, ref}, state)
      {state, commands} = Update.update({:run_step, ref}, state)

      assert step_status(state, "sync") == "failed"
      assert step_status(state, "verify") == "skipped"
      assert state.phase == :done
      assert [%Command{kind: :timer}] = commands
      assert [%{id: :update_result, type: :error}] = state.toasts.toasts
    end

    test "stale chain messages are dropped" do
      state = state()

      assert %Update{} = Update.update({:run_step, make_ref()}, state)
      assert step_status(state, "pull") == "pending"
    end

    test "q is Command.shutdown(:normal)" do
      assert {state, [%Command{kind: :shutdown, value: :normal}]} =
               Update.update({:text, "q"}, state())

      assert %Update{} = state
    end

    defp step_status(state, id) do
      Enum.find_value(state.steps, fn step -> step["id"] == id && step["status"] end)
    end
  end
end
