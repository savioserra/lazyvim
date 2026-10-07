defmodule Workstation.CLI.TUI.ApplyTest do
  use ExUnit.Case, async: true

  import Workstation.CLITest.TUI

  alias TermUI.{Command, Event, Frame}
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
            toast_ms: 60_000,
            executor: &Apply.dry_run_executor/1,
            # Tests never touch a daemon: the availability check defaults
            # to the daemon op, so every screen run pins a silent verdict
            # unless the test asserts the indicator itself.
            check: fn -> {:ok, %{"status" => "up_to_date"}} end
          ],
          extra
        )
    ]
  end

  defp start_apply(extra \\ []), do: start_screen!(Apply, screen_opts(extra))

  # Arms the run through the typed-confirm gate (spec §2.3): `a` opens
  # the gate, the typed verb arms it, Enter fires.
  defp arm(runtime) do
    send_text(runtime, "a")
    type_text(runtime, "apply")
    send_key(runtime, :enter)
  end

  # Layout with rows: 12: box borders 1/12 (title + counters on 1, phase
  # buttonbar on 12), table header row 2, entries 3-5; the confirm dialog
  # box overlays rows 4-8; the newest toast box overlays rows 10-12. The
  # table inset starts at column 2 (column 1 is the box border), so cursor
  # cells are read at column 2. Columns are 80 wide so the longest
  # capability id renders unclipped.
  describe "view" do
    test "header shows destination and generation, table shows entries, footer hints" do
      start_apply()
      frame = latest_frame()

      assert frame |> Frame.row_text(1) =~ "apply · #{@destination}"
      assert frame |> Frame.row_text(1) =~ "gen gen-1"
      assert frame |> Frame.row_text(1) =~ "3 changes"

      assert frame |> Frame.row_text(2) =~ "CAPABILITY"
      assert frame |> Frame.row_text(2) =~ "OPERATION"
      assert frame |> Frame.row_text(2) =~ "TARGET"

      assert frame |> Frame.row_text(3) =~ "modify_executable_dot_bashrc"
      assert frame |> Frame.row_text(3) =~ "modify"
      assert frame |> Frame.row_text(3) =~ ".bashrc"
      assert frame |> Frame.row_text(4) =~ "dot_config/nvim/init.lua"
      assert frame |> Frame.row_text(5) =~ "dot_tmux.conf"

      assert frame |> Frame.row_text(12) =~ "a confirm"
      assert frame |> Frame.row_text(12) =~ "q quit"
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
      assert :reverse in Frame.cell(frame, 4, 2).attrs
      refute :reverse in Frame.cell(frame, 3, 2).attrs
    end

    test "native key events move the cursor the same way" do
      runtime = start_apply()
      send_key(runtime, :down)
      send_key(runtime, :down)

      # Key events process through the screen's event loop — wait for
      # the moved cursor instead of trusting one drain.
      frame =
        await_frame(fn frame ->
          :reverse in Frame.cell(frame, 5, 2).attrs
        end)

      assert :reverse in Frame.cell(frame, 5, 2).attrs
    end

    test "enter selects the cursor row" do
      runtime = start_apply()
      send_text(runtime, "↓")
      send_key(runtime, :enter)
      # The cursor row always renders with the cursor style, so step the
      # cursor off the selection to observe the selected style.
      send_key(runtime, :up)

      frame = latest_frame()
      cell = Frame.cell(frame, 4, 2)

      assert :bold in cell.attrs
      assert cell.fg == :cyan
    end

    test "home and end jump to the boundaries" do
      runtime = start_apply()
      send_key(runtime, :end)

      frame = latest_frame()
      assert :reverse in Frame.cell(frame, 5, 2).attrs

      send_key(runtime, :home)
      frame = latest_frame()
      assert :reverse in Frame.cell(frame, 3, 2).attrs
    end
  end

  describe "confirm dialog" do
    test "a opens the confirm dialog" do
      runtime = start_apply()
      send_text(runtime, "a")

      frame = latest_frame()

      assert frame |> Frame.row_text(4) =~ "Confirm apply"
      assert frame |> Frame.row_text(5) =~ "Apply 3 change(s) to #{@destination}?"
      assert frame |> Frame.row_text(6) =~ "Type apply to confirm: _"
      assert frame |> Frame.row_text(12) =~ "enter confirm apply"
      assert frame |> Frame.row_text(12) =~ "n cancel"
      assert frame |> Frame.row_text(12) =~ "q quit"
    end

    test "the buffer echoes keystrokes and a wrong verb never arms" do
      runtime = start_apply()
      send_text(runtime, "a")
      type_text(runtime, "upda")

      frame = latest_frame()
      assert frame |> Frame.row_text(6) =~ "Type apply to confirm: upda_"

      type_text(runtime, "te")
      send_key(runtime, :enter)
      frame = latest_frame()

      # "update" is the wrong verb on the apply screen: the gate stays up.
      assert frame |> Frame.row_text(4) =~ "Confirm apply"
      refute frame |> Frame.row_text(11) =~ "Applied"
    end

    test "n cancels back to ready" do
      runtime = start_apply()
      send_text(runtime, "a")
      _frame = latest_frame()
      send_text(runtime, "n")

      frame = latest_frame()
      refute frame |> Frame.row_text(4) =~ "Confirm apply"
      assert frame |> Frame.row_text(12) =~ "a confirm"
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

      arm(runtime)

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

      arm(runtime)

      frame = latest_frame()
      assert frame |> Frame.row_text(11) =~ "× Apply failed: engine refused"
    end

    test "toast expires through its own timer command" do
      runtime = start_apply(toast_ms: 30)

      arm(runtime)
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

  describe "availability indicator (supervisor-directed scope)" do
    test "a behind verdict surfaces the accent footer and the [u] affordance" do
      runtime =
        start_apply(
          toast_ms: 30,
          check: fn ->
            {:ok, %{"status" => "behind", "local" => "abc1234", "remote" => "def5678"}}
          end
        )

      # Consume the open frame, expire the completion toast, then force a
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
        start_apply(check: fn -> verdict end)
        frame = latest_frame()
        refute frame |> Frame.row_text(12) =~ "update available"
      end
    end
  end

  describe "pure update/2 contract" do
    defp state do
      {state, _check_start} =
        Apply.init(
          destination: @destination,
          plan: @plan,
          theme: Theme.base_colors(:dark),
          dimensions: {64, 12},
          toast_ms: 1_000,
          # The pure contract tests need a succeeding executor: the default is
          # the daemon-orchestrated path, which refuses without a daemon.
          executor: &Apply.dry_run_executor/1,
          check: fn -> {:ok, %{"status" => "up_to_date"}} end
        )

      state
    end

    # Non-command clauses return a bare state, command clauses a
    # {state, commands} tuple — the screen's update/2 contract.
    defp send_msg(state, msg) do
      case Apply.update(msg, state) do
        {state, _commands} -> state
        %Apply{} = state -> state
      end
    end

    # Arms a run through the gate exactly as an operator would: a, the
    # verb, Enter.
    defp armed_state do
      state = send_msg(state(), {:text, "a"})

      state =
        Enum.reduce(String.graphemes("apply"), state, fn ch, acc ->
          send_msg(acc, {:text, ch})
        end)

      {state, [%Command{kind: :async}]} = Apply.update({:key, :enter}, state)
      state
    end

    test "the run is one async op; run.started captures the stream token" do
      state = armed_state()
      %{run: %{ref: ref, op_ref: nil}} = state
      assert state.phase == :running

      state =
        Apply.update(
          {:apply_event, ref, %{"type" => "run.started", "op" => "apply.run", "op_ref" => "op-7"}},
          state
        )

      assert %{run: %{op_ref: "op-7"}} = state
    end

    test "apply_done settles the run with the token-guarded toast" do
      state = armed_state()
      %{run: %{ref: ref}} = state

      {state, commands} = Apply.update({:apply_done, ref, :ok}, state)

      assert state.phase == :done
      assert state.run == nil
      assert [%Command{kind: :timer}] = commands
      assert [%{id: :apply_result, type: :success}] = state.toasts.toasts
    end

    test "executor failure reports an error toast" do
      state = armed_state()
      %{run: %{ref: ref}} = state
      {state, _commands} = Apply.update({:apply_done, ref, {:error, "engine refused"}}, state)

      assert state.phase == :done
      assert [%{id: :apply_result, type: :error}] = state.toasts.toasts
    end

    test "stale events and results from a superseded run are dropped" do
      state = armed_state()

      stale_event = %{"type" => "run.started", "op" => "apply.run", "op_ref" => "op-x"}

      assert %Apply{} = state = Apply.update({:apply_event, make_ref(), stale_event}, state)
      assert %{run: %{op_ref: nil}} = state

      assert %Apply{} = state = Apply.update({:apply_done, make_ref(), :ok}, state)
      assert state.phase == :running
    end

    test "check_done folds only behind verdicts into the hint" do
      state = state()

      state =
        Apply.update(
          {:check_done, {:ok, %{"status" => "behind", "local" => "abc1234", "remote" => "def5678"}}},
          state
        )

      assert state.update_hint == %{"local" => "abc1234", "remote" => "def5678"}

      state = Apply.update({:check_done, {:ok, %{"status" => "unknown", "reason" => "offline"}}}, state)
      assert state.update_hint == nil
    end

    test "u hands off to the standard update flow only with a surfaced hint" do
      test_pid = self()

      {state, _check} =
        Apply.init(
          destination: @destination,
          plan: @plan,
          theme: Theme.base_colors(:dark),
          dimensions: {64, 12},
          toast_ms: 1_000,
          executor: &Apply.dry_run_executor/1,
          check: fn -> {:ok, %{"status" => "up_to_date"}} end,
          tui_caller: test_pid
        )

      # No hint: u is inert.
      assert %Apply{phase: :ready} = Apply.update({:text, "u"}, state)

      state =
        Apply.update(
          {:check_done, {:ok, %{"status" => "behind", "local" => "abc1234", "remote" => "def5678"}}},
          state
        )

      assert {_state, [%Command{kind: :shutdown, value: :normal}]} =
               Apply.update({:text, "u"}, state)

      assert_receive {:tui_request, {:run_update, @destination}}
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

    test "duplicated source names get a stable occurrence suffix" do
      plan = %{
        "generation" => "g",
        "plan" => %{
          "entries" => [
            %{"source_name" => "dot_gitconfig", "type" => "file", "target" => ".gitconfig"},
            %{"source_name" => "dot_tmux.conf", "type" => "file", "target" => ".tmux.conf"},
            %{"source_name" => "dot_tmux.conf", "type" => "modify", "target" => ".tmux.conf"},
            %{"source_name" => "dot_tmux.conf", "type" => "file", "target" => "other/tmux.conf"}
          ]
        }
      }

      ids = Apply.entries_from_plan(plan) |> Enum.map(& &1["id"])

      # unique names keep the bare production key; a source carrying several
      # operations is disambiguated by occurrence, deterministically ordered
      assert ids == ["dot_gitconfig", "dot_tmux.conf#1", "dot_tmux.conf#2", "dot_tmux.conf#3"]
      assert Enum.uniq(ids) == ids
    end
  end
end
