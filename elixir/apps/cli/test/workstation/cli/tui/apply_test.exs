defmodule Workstation.CLI.TUI.ApplyTest do
  use ExUnit.Case, async: true

  import Workstation.CLITest.TUI

  alias TermUI.{Command, Frame}
  alias Workstation.CLI.TUI.Apply
  alias Workstation.CLI.TUI.Theme

  @destination "/home/test"

  # Plan wire in the production entry-view shape: the identity key is
  # `source_name` — exactly what Workstation.CLI.Core's entry view emits
  # (never `name`, the golden projection's spelling of the same value);
  # entries are already in canonical engine order.
  @plan %{
    "schema" => "workstation.plan.v1",
    "generation" => "gen-1",
    "plan" => %{
      "entries" => [
        %{
          "source_name" => "modify_executable_dot_bashrc",
          "operation" => "modify",
          "target" => ".bashrc"
        },
        %{
          "source_name" => "dot_config/nvim/init.lua",
          "operation" => "file",
          "target" => ".config/nvim/init.lua"
        },
        %{"source_name" => "dot_tmux.conf", "operation" => "file", "target" => ".tmux.conf"}
      ]
    }
  }

  defp screen_opts(extra) do
    [
      rows: 12,
      cols: 80,
      screen_opts:
        Keyword.merge(
          [
            destination: @destination,
            plan: @plan,
            theme: Theme.base_colors(:dark),
            tick_ms: 1,
            toast_ms: 60_000,
            executor: &Apply.dry_run_executor/1
          ],
          extra
        )
    ]
  end

  defp start_apply(extra \\ []), do: start_screen!(Apply, screen_opts(extra))

  # Layout with rows: 12: header 1-2, table header row 3, entries 4-6,
  # footer 12; dialog box rows 4-8; newest toast box rows 10-12. Columns
  # are 80 wide so the longest capability id renders unclipped.
  describe "view" do
    test "header shows destination and generation, table shows entries, footer hints" do
      start_apply()
      frame = latest_frame()

      assert frame |> Frame.row_text(1) =~ "workstation apply"
      assert frame |> Frame.row_text(1) =~ @destination
      assert frame |> Frame.row_text(2) =~ "generation gen-1 · 3 change(s)"

      assert frame |> Frame.row_text(3) =~ "CAPABILITY"
      assert frame |> Frame.row_text(3) =~ "OPERATION"
      assert frame |> Frame.row_text(3) =~ "TARGET"

      assert frame |> Frame.row_text(4) =~ "modify_executable_dot_bashrc"
      assert frame |> Frame.row_text(4) =~ "modify"
      assert frame |> Frame.row_text(4) =~ ".bashrc"
      assert frame |> Frame.row_text(5) =~ "dot_config/nvim/init.lua"
      assert frame |> Frame.row_text(6) =~ "dot_tmux.conf"

      assert frame |> Frame.row_text(12) =~ "a confirm · ↑↓ move · enter select · q quit"
    end

    test "header accent renders as resolved rgb color" do
      start_apply()
      frame = latest_frame()

      # Theme.accent resolves to a term_ui rgb tint, never a slot name.
      refute frame |> Frame.cell(1, 1) |> Map.get(:fg) == :default
    end
  end

  describe "cursor and selection" do
    test "arrow glyph text moves the cursor" do
      runtime = start_apply()
      send_text(runtime, "↓")

      frame = latest_frame()
      assert :reverse in Frame.cell(frame, 5, 1).attrs
      refute :reverse in Frame.cell(frame, 4, 1).attrs
    end

    test "native key events move the cursor the same way" do
      runtime = start_apply()
      send_key(runtime, :down)
      send_key(runtime, :down)

      frame = latest_frame()
      assert :reverse in Frame.cell(frame, 6, 1).attrs
    end

    test "enter selects the cursor row" do
      runtime = start_apply()
      send_text(runtime, "↓")
      send_key(runtime, :enter)
      # The cursor row always renders with the cursor style, so step the
      # cursor off the selection to observe the selected style.
      send_key(runtime, :up)

      frame = latest_frame()
      cell = Frame.cell(frame, 5, 1)

      assert :bold in cell.attrs
      assert cell.fg == :cyan
    end

    test "home and end jump to the boundaries" do
      runtime = start_apply()
      send_key(runtime, :end)

      frame = latest_frame()
      assert :reverse in Frame.cell(frame, 6, 1).attrs

      send_key(runtime, :home)
      frame = latest_frame()
      assert :reverse in Frame.cell(frame, 4, 1).attrs
    end
  end

  describe "confirm dialog" do
    test "a opens the confirm dialog" do
      runtime = start_apply()
      send_text(runtime, "a")

      frame = latest_frame()

      assert frame |> Frame.row_text(4) =~ "Confirm apply"
      assert frame |> Frame.row_text(5) =~ "Apply 3 change(s) to #{@destination}?"
      assert frame |> Frame.row_text(7) =~ "[ Yes ]"
      assert frame |> Frame.row_text(7) =~ "[ No ]"
      assert frame |> Frame.row_text(12) =~ "y confirm apply · n/esc cancel · q quit"
    end

    test "n cancels back to ready" do
      runtime = start_apply()
      send_text(runtime, "a")
      _frame = latest_frame()
      send_text(runtime, "n")

      frame = latest_frame()
      refute frame |> Frame.row_text(4) =~ "Confirm apply"
      assert frame |> Frame.row_text(12) =~ "a confirm · ↑↓ move · enter select · q quit"
    end

    test "escape cancels back to ready" do
      runtime = start_apply()
      send_text(runtime, "a")
      _frame = latest_frame()
      send_key(runtime, :escape)

      frame = latest_frame()
      refute frame |> Frame.row_text(4) =~ "Confirm apply"
    end
  end

  describe "apply run" do
    test "y runs the executor and reports success with a token-guarded toast" do
      test_pid = self()

      runtime =
        start_apply(
          executor: fn %{"entries" => entries, "generation" => generation} ->
            send(test_pid, {:executor_called, entries, generation})
            :ok
          end
        )

      send_text(runtime, "a")
      send_text(runtime, "y")

      assert_receive {:executor_called, entries, generation}, 2_000
      # The request-map contract (b8): the executor sees what the daemon op
      # schema validates — the plan's generation plus the screen's rows.
      assert generation == "gen-1"
      assert length(entries) == 3
      assert %{"id" => "modify_executable_dot_bashrc"} = hd(entries)

      frame = latest_frame()

      assert frame |> Frame.row_text(11) =~ "✓ Applied generation gen-1"
      assert frame |> Frame.row_text(12) =~ "q quit"
    end

    test "executor failure reports an error toast and keeps the tree green" do
      runtime = start_apply(executor: fn _entries -> {:error, "engine refused"} end)

      send_text(runtime, "a")
      send_text(runtime, "y")

      frame = latest_frame()
      assert frame |> Frame.row_text(11) =~ "× Apply failed: engine refused"
    end

    test "toast expires through its own timer command" do
      runtime = start_apply(toast_ms: 30)

      send_text(runtime, "a")
      send_text(runtime, "y")
      # toast_ms 30 expires inside the drain's quiet window, so the first
      # frame is already post-expiry; force a redraw and assert on that.
      _visible = latest_frame()
      send_event(runtime, TermUI.Event.resize(80, 12))

      frame = latest_frame()
      refute frame |> Frame.row_text(11) =~ "Applied generation"
    end

    test "q shuts the screen down with reason :normal" do
      runtime = start_apply()
      send_text(runtime, "q")

      snapshot = shutdown_snapshot()
      assert snapshot.shutdown_reason == :normal
    end
  end

  describe "pure update/2 contract" do
    defp state do
      Apply.init(
        destination: @destination,
        plan: @plan,
        theme: Theme.base_colors(:dark),
        dimensions: {64, 12},
        tick_ms: 5,
        toast_ms: 1_000,
        # The pure contract tests need a succeeding executor: the default is
        # the daemon-orchestrated path, which refuses without a daemon.
        executor: &Apply.dry_run_executor/1
      )
    end

    test "progress advances 0→100 in timer ticks through update/2" do
      state = state()
      assert state.progress.value == 0

      state = Apply.update({:text, "a"}, state)
      {state, commands} = Apply.update({:text, "y"}, state)
      %{run: %{ref: ref}} = state
      assert [%Command{kind: :timer, value: {5, {:apply_tick, ^ref}}}] = commands

      # Nine mid-run ticks keep returning timer commands; the tenth lands on
      # 100 and resolves into the toast + its own expiry timer command.
      {state, [_timer]} = Apply.update({:apply_tick, ref}, state)
      assert state.progress.value == 10

      {state, commands} =
        Enum.reduce(2..10, {state, []}, fn _tick, {state, _prev} ->
          Apply.update({:apply_tick, ref}, state)
        end)

      assert state.progress.value == 100
      assert state.phase == :done

      # The final tick resolves into a toast whose expiry is a timer command
      # (token-guarded), not a silent disappearance.
      assert [%Command{kind: :timer}] = commands
      assert [%{id: :apply_result, type: :success}] = state.toasts.toasts
    end

    test "stale ticks from a superseded run are dropped" do
      state = state()
      state = Apply.update({:text, "a"}, state)

      {state, [%Command{kind: :timer, value: {_ms, {:apply_tick, _started_ref}}}]} =
        Apply.update({:text, "y"}, state)

      assert %Apply{} = Apply.update({:apply_tick, make_ref()}, state)
      assert state.progress.value == 0
    end

    test "q is Command.shutdown(:normal)" do
      assert {state, [%Command{kind: :shutdown, value: :normal}]} =
               Apply.update({:text, "q"}, state())

      assert %Apply{} = state
    end

    test "n and escape cancel the dialog" do
      state = state()
      state = Apply.update({:text, "a"}, state)
      assert state.phase == :dialog

      assert %{phase: :ready} = Apply.update({:text, "n"}, state)

      state = Apply.update({:text, "a"}, state)
      assert %{phase: :ready} = Apply.update({:key, :escape}, state)
    end
  end

  describe "entries_from_plan" do
    test "maps plan entries to table rows and tolerates an empty body" do
      entries = Apply.entries_from_plan(@plan)

      assert entries == [
               %{
                 "id" => "modify_executable_dot_bashrc",
                 "operation" => "modify",
                 "target" => ".bashrc"
               },
               %{
                 "id" => "dot_config/nvim/init.lua",
                 "operation" => "file",
                 "target" => ".config/nvim/init.lua"
               },
               %{"id" => "dot_tmux.conf", "operation" => "file", "target" => ".tmux.conf"}
             ]

      assert Apply.entries_from_plan(%{"generation" => "g"}) == []
    end
  end
end
