defmodule Workstation.CLI.TUI.Apply do
  @moduledoc """
  The §5 apply screen: ONE full-screen rounded box (capability table
  inset, cursor keys), the box border carrying the title island,
  generation/change counters and the phase's buttonbar (keycap islands),
  confirm dialog (`a`), daemon-driven apply with live abort, token-guarded
  success/error Toast, cancel (`n`/Escape), quit (`q`).

  The screen owns the INTERACTION contract only. Anatomy: ONE full-screen
  rounded box — the top border carries the `apply` island and the
  destination, the top-right islands carry the generation + change
  counters, the bottom border is the phase's buttonbar (confirm/move keys,
  abort/detach while running, quit), and the daemon-driven plan table sits
  inset inside the box. The apply itself is the
  `:executor` callback invoked once on confirm — ONE daemon op
  (`apply.run`, generation + entries) whose task runs OUTSIDE the Elm loop
  (`Command.async/2`); the op's event frames come back through
  `TermUI.send_message/2` and its eventual result as the async
  completion, so every transition resolves through pure `update/2` and the
  deterministic backend can replay a recorded run. Production runs wire
  `Workstation.CLI.TUI.Executor`; an unconfigured screen still renders and
  confirms on the pure `dry_run_executor/1` with no mutation path at all.

  Progress is EVENT-driven at the boundaries the daemon actually reports:
  `apply.run` publishes `run.started`/`run.finished` (entry-level progress
  would need core applier hooks, and core/ is frozen by contract — the
  deferral is recorded in docs/capabilities.md). While the op runs the
  buttonbar states the fact and offers `x` abort (`op.abort`; the daemon
  cancels at its next step boundary) and `q` detach (the daemon keeps the
  lock and finishes without a viewer); the completion toast carries the
  executor's verdict.

  The passive availability indicator (supervisor-directed engine scope)
  fires `update.check` asynchronously on screen open; when the branch is
  behind, the buttonbar surfaces the accent indicator island and `u`
  hands off to the standard update flow (the router launches the update
  screen).
  """

  use TermUI.Elm

  alias TermUI.{Command, Event, Frame, Layout, Runtime, Style}
  alias TermUI.Widget.{AlertDialog, Helpers, Table}
  alias TermUI.Widget.Table.Column
  alias TermUI.Widget.Toast.Manager

  alias Workstation.CLI.TUI.{Executor, Shell.Box, Theme, UpdateHint}

  @enforce_keys [
    :destination,
    :generation,
    :entries,
    :table,
    :dialog,
    :toasts,
    :phase,
    :run,
    :theme,
    :dimensions,
    :executor,
    :check,
    :toast_ms
  ]
  defstruct [
    :destination,
    :generation,
    :entries,
    :table,
    :dialog,
    :toasts,
    :phase,
    :run,
    :theme,
    :dimensions,
    :executor,
    :check,
    :update_hint,
    :tui_caller,
    :toast_ms
  ]

  @type phase :: :ready | :dialog | :running | :done
  @type run_token :: reference()

  @type t :: %__MODULE__{
          destination: String.t(),
          generation: String.t(),
          entries: [map()],
          table: Table.t(),
          dialog: AlertDialog.t(),
          toasts: Manager.t(),
          phase: phase(),
          run: %{ref: run_token(), op_ref: String.t() | nil, outcome: :ok | {:error, term()}} | nil,
          theme: Theme.colors(),
          dimensions: {pos_integer(), pos_integer()},
          executor: (map() -> :ok | {:error, term()}),
          check: (() -> {:ok, map()} | {:error, term()}),
          update_hint: UpdateHint.hint() | nil,
          tui_caller: pid() | nil,
          toast_ms: pos_integer()
        }

  # Footer grammar is rendered as buttonbar islands (see footer_buttons/1).

  @doc """
  Default executor: the pure pre-graduation stand-in. Production runs use
  `Workstation.CLI.TUI.Executor` (the daemon-orchestrated path); the pure
  stand-in stays the default so an accidental unconfigured run can never
  mutate anything.
  """
  @spec dry_run_executor(map()) :: :ok
  def dry_run_executor(_request), do: :ok

  @doc """
  Table rows for the plan body's entries, in canonical engine order. The row
  id is the entry's `source_name` — the identity key the production entry
  view carries (the recorded golden projection spells the same value `name`).

  One source can carry several operations in one generation, so a duplicated
  `source_name` gets a stable occurrence suffix (`name#2`); unique names keep
  the bare production key. Row ids must be unique — the table widget refuses
  duplicate identities at init.
  """
  @spec entries_from_plan(map()) :: [map()]
  def entries_from_plan(plan) do
    entries =
      plan
      |> get_in(["plan", "entries"])
      |> case do
        entries when is_list(entries) -> entries
        _other -> []
      end

    counts = Enum.frequencies_by(entries, & &1["source_name"])

    {rows, _seen} =
      Enum.map_reduce(entries, %{}, fn entry, seen ->
        name = entry["source_name"]

        {id, seen} =
          if counts[name] > 1 do
            occurrence = Map.get(seen, name, 0) + 1
            {"#{name}##{occurrence}", Map.put(seen, name, occurrence)}
          else
            {name, seen}
          end

        row = %{
          "id" => id,
          "operation" => entry["operation"] || entry["type"],
          "target" => entry["target"]
        }

        {row, seen}
      end)

    rows
  end

  @impl TermUI.Elm
  def init(opts) do
    destination = Keyword.fetch!(opts, :destination)
    plan = Keyword.fetch!(opts, :plan)
    entries = entries_from_plan(plan)

    state = %__MODULE__{
      destination: destination,
      generation: Map.fetch!(plan, "generation"),
      entries: entries,
      table: Table.init(rows: entries, columns: columns(), row_id: "id", selection_mode: :single),
      dialog:
        AlertDialog.init(
          type: :confirm,
          title: "Confirm apply",
          message: "Apply #{length(entries)} change(s) to #{destination}?",
          dismiss_message: :dialog_cancel
        ),
      toasts: Manager.new(id: :apply_toasts),
      phase: :ready,
      run: nil,
      theme: Keyword.fetch!(opts, :theme),
      dimensions: Keyword.fetch!(opts, :dimensions),
      executor: Keyword.get(opts, :executor, &Executor.apply_executor/1),
      check: Keyword.get(opts, :check, &Executor.update_check_executor/0),
      update_hint: nil,
      tui_caller: Keyword.get(opts, :tui_caller),
      toast_ms: Keyword.get(opts, :toast_ms, 5_000)
    }

    # Screen-open effect: one asynchronous availability check (silent
    # unless the branch is behind).
    {state, check_commands(state)}
  end

  @doc """
  Normalize events to screen messages. Terminal arrow keys surface both as
  native key events and (on some terminals/backends) as text glyphs, so
  both spellings collapse to one `{:key, ...}` message and the screens
  behave identically on a real TTY and under the deterministic test backend.
  """
  @spec event_to_msg(Event.t(), t()) :: {:msg, term()} | :ignore
  @impl TermUI.Elm
  def event_to_msg(%Event.Text{text: "↑"}, _state), do: {:msg, {:key, :up}}
  def event_to_msg(%Event.Text{text: "↓"}, _state), do: {:msg, {:key, :down}}
  def event_to_msg(%Event.Text{text: text}, _state), do: {:msg, {:text, text}}

  def event_to_msg(%Event.Key{key: key}, _state), do: {:msg, {:key, key}}

  def event_to_msg(%Event.Resize{width: width, height: height}, _state),
    do: {:msg, {:resize, width, height}}

  def event_to_msg(_event, _state), do: :ignore

  @impl TermUI.Elm
  def update({:key, key}, %{phase: :ready} = state)
      when key in [:up, :down, :home, :end, :page_up, :page_down, :enter] do
    {table, _messages} = Table.update(Event.key(key), state.table)
    %{state | table: table}
  end

  def update({:key, key}, %{phase: :dialog} = state)
      when key in [:up, :down, :left, :right, :tab, :enter] do
    # Dialog buttons are navigated with the same keys; the screen keeps its
    # own y/n/Escape contract and ignores dialog button activation messages.
    {dialog, _messages} = AlertDialog.update(Event.key(key), state.dialog)
    %{state | dialog: dialog}
  end

  def update({:text, "a"}, %{phase: :ready} = state), do: %{state | phase: :dialog}

  def update({:text, "y"}, %{phase: :dialog} = state), do: start_run(state)

  def update({:text, "n"}, %{phase: :dialog} = state), do: %{state | phase: :ready}
  def update({:key, :escape}, %{phase: :dialog} = state), do: %{state | phase: :ready}

  # Abort: forwards op.abort with the stream token; the daemon settles the
  # op at its next boundary and the completion path paints the verdict (a
  # racing finish surfaces as the abort executor's error value, dropped).
  def update({:text, "x"}, %{phase: :running, run: %{op_ref: op_ref}} = state)
      when is_binary(op_ref) do
    {state, [Command.async(fn -> Executor.abort_executor(op_ref) end, fn _result -> :noop end)]}
  end

  def update(:noop, state), do: state

  # Handoff to the standard update flow: only offered while the indicator
  # is showing (the `[u]` affordance) and the screen is idle. The request
  # rides to the CLI process that launched the TUI (injected as
  # `:tui_caller`), which then runs the update screen.
  def update({:text, "u"}, %{phase: phase, update_hint: hint, tui_caller: caller} = state)
      when phase in [:ready, :done] and hint != nil do
    if is_pid(caller), do: send(caller, {:tui_request, {:run_update, state.destination}})
    {state, [Command.shutdown(:normal)]}
  end

  def update({:text, "q"}, state), do: {state, [Command.shutdown(:normal)]}

  def update({:apply_event, ref, %{"type" => "run.started", "op_ref" => op_ref}},
             %{phase: :running, run: %{ref: ref}} = state) do
    %{state | run: %{state.run | op_ref: op_ref}}
  end

  def update({:apply_event, _stale_ref, _event}, state), do: state

  def update({:apply_done, ref, outcome}, %{phase: :running, run: %{ref: ref}} = state) do
    finish_run(%{state | run: %{state.run | outcome: outcome}})
  end

  def update({:apply_done, _stale_ref, _outcome}, state), do: state

  # The check result folds through UpdateHint: only "behind" surfaces,
  # everything else (up_to_date, unknown, transport error) is silent.
  def update({:check_done, verdict}, state) do
    %{state | update_hint: UpdateHint.fold(verdict)}
  end

  def update({:term_ui_toast_expire, _manager_id, _toast_id, _token} = expire, state),
    do: %{state | toasts: Manager.expire(state.toasts, expire)}

  def update({:dialog_cancel, :cancel}, state), do: %{state | phase: :ready}

  def update({:resize, width, height}, state), do: %{state | dimensions: {width, height}}

  def update(_message, state), do: state

  @impl TermUI.Elm
  def view(state, underlay \\ :none) do
    {width, height} = state.dimensions

    case state.phase do
      phase when phase in [:running, :done] ->
        base = if is_map(underlay), do: underlay, else: Helpers.frame([], {width, height})

        case run_rect(width, height) do
          :full ->
            # A compact screen keeps the full review surface; the toast
            # still lands as the OK box.
            Helpers.frame([], {width, height})
            |> Helpers.compose(Layout.new({width, height}), fn dims ->
              screen_frame(state, dims)
            end)
            |> overlay_toasts(state)

          rect ->
            base
            |> overlay_run_panel(state, rect)
            |> overlay_toasts(state)
        end

      _ ->
        Helpers.frame([], {width, height})
        |> Helpers.compose(Layout.new({width, height}), fn dims -> screen_frame(state, dims) end)
        |> overlay_dialog(state)
        |> overlay_toasts(state)
    end
  end

  # §1.6: at shell scale the run renders as a small box floating over
  # the living dashboard (the shell hands its mirror in as the underlay)
  # — journal and plan keep streaming underneath while the panel carries
  # the phase line and the abort/return islands; the result toast lands
  # bottom-right as the OK box. Below the float threshold the surface
  # keeps the full rect.
  defp run_rect(width, height) when height < 16 or width < 60, do: :full

  defp run_rect(width, height) do
    panel_width = min(56, width - 12)
    panel_height = min(7, height - 8)
    x = div(width - panel_width, 2)
    y = div(height - panel_height, 2)
    {panel_width, panel_height, x, y}
  end

  defp overlay_run_panel(frame, state, {panel_width, panel_height, x, y}) do

    panel =
      Box.frame(run_rows(state), {panel_width, panel_height},
        border_style: role_style(state, :accent),
        title: [
          {" apply ", bold_role(state, :accent)},
          {"· ", role_style(state, :chrome)},
          {state.destination <> " ", Style.new()}
        ],
        right: [
          [{"gen ", role_style(state, :chrome)}, {state.generation, bold_role(state, :accent)}],
          [{"#{length(state.entries)} changes", role_style(state, :chrome)}]
        ],
        buttons: footer_buttons(state)
      )

    Frame.overlay(frame, panel, x + 1, y + 1)
  end

  defp run_rows(%{phase: :running} = state) do
    [[{"applying — x aborts; the dashboard underneath keeps streaming", role_style(state, :text)}]]
  end

  defp run_rows(%{phase: :done} = state) do
    [[{"applied — the dashboard below is live again", role_style(state, :text)}]]
  end

  # The boxed op screen: the plan table inset inside one rounded box whose
  # border carries the title, counters, and the phase's buttonbar.
  defp screen_frame(state, {width, height} = dims) do
    box =
      Box.frame([], dims,
        border_style: role_style(state, :chrome),
        title: [
          {" apply ", bold_role(state, :accent)},
          {"· ", role_style(state, :chrome)},
          {state.destination <> " ", Style.new()}
        ],
        right: [
          [{"gen ", role_style(state, :chrome)}, {state.generation, bold_role(state, :accent)}],
          [{"#{length(state.entries)} changes", role_style(state, :chrome)}]
        ],
        buttons: footer_buttons(state)
      )

    table = Table.view(state.table, {max(width - 2, 1), max(height - 2, 1)})

    # 1-based overlay: the box starts at row/col 1, the table inset sits at
    # row/col 2 inside the border.
    Frame.overlay(box, table, 2, 2)
  end

  # The bottom border is the phase's action bar; every key is its own
  # island (btop keycaps), the update indicator rides as its own island
  # when it shows.
  defp footer_buttons(%{phase: :running} = state) do
    [[{"applying", bold_role(state, :accent)}]] ++ key_islands(state, x: "abort", q: "detach")
  end

  defp footer_buttons(%{phase: :dialog} = state), do: key_islands(state, y: "confirm apply", n: "cancel", q: "quit")

  defp footer_buttons(%{phase: :done, update_hint: hint} = state) when hint != nil do
    key_islands(state, q: "quit") ++ [[{UpdateHint.text(hint), bold_role(state, :accent)}]]
  end

  defp footer_buttons(%{phase: :done} = state), do: key_islands(state, q: "quit")

  defp footer_buttons(%{phase: :ready, update_hint: hint} = state) when hint != nil do
    [[{UpdateHint.text(hint), bold_role(state, :accent)}]] ++ key_islands(state, a: "confirm", q: "quit")
  end

  defp footer_buttons(%{phase: :ready} = state) do
    key_islands(state, a: "confirm", q: "quit")
  end

  # One island per key: the cap rides the bold accent slot, the label
  # follows plain — btop's border-button grammar.
  defp key_islands(state, pairs) do
    Enum.map(pairs, fn {cap, label} ->
      [{Atom.to_string(cap), bold_role(state, :accent)}, {" #{label}", Style.new()}]
    end)
  end

  ## run lifecycle

  # ONE daemon op on confirm; the events sink queues each frame back into
  # THIS runtime's Elm loop (self() during init/update is the runtime
  # process), token-guarded by the run reference.
  defp start_run(state) do
    ref = make_ref()
    runtime = self()

    request = %{
      "generation" => state.generation,
      "entries" => state.entries,
      "events" => fn event -> Runtime.send_message(runtime, {:apply_event, ref, event}) end
    }

    command =
      Command.async(fn -> state.executor.(request) end, fn
        {:ok, outcome} -> {:apply_done, ref, outcome}
        {:error, reason} -> {:apply_done, ref, {:error, inspect(reason, pretty: false)}}
      end)

    {%{state | phase: :running, run: %{ref: ref, op_ref: nil, outcome: nil}}, [command]}
  end

  defp finish_run(state) do
    {message, type} =
      case state.run.outcome do
        :ok -> {"Applied generation #{state.generation}", :success}
        {:error, reason} -> {"Apply failed: #{reason}", :error}
      end

    {toasts, commands} =
      Manager.add_with_timer(state.toasts, message, type,
        id: :apply_result,
        duration: state.toast_ms
      )

    {%{state | phase: :done, run: nil, toasts: toasts}, commands}
  end

  defp check_commands(state) do
    # Total mapper (a raising check degrades to silence, never takes the
    # loop down) that unwraps the runtime's {:ok, _} envelope: the screen
    # sees the executor's own {:ok, verdict} | {:error, message} shape.
    [
      Command.async(state.check, fn
        {:ok, result} -> {:check_done, result}
        {:error, reason} -> {:check_done, {:error, inspect(reason, pretty: false)}}
      end)
    ]
  end

  ## rendering

  defp columns do
    [
      Column.new("id", "CAPABILITY", width: 30),
      Column.new("operation", "OPERATION", width: 12),
      Column.new("target", "TARGET")
    ]
  end

  defp role_style(state, role), do: %Style{fg: Theme.to_term_ui_color(state.theme[role])}

  defp bold_role(state, role) do
    case Theme.to_term_ui_color(state.theme[role]) do
      {:rgb, r, g, b} -> Style.new(fg: {:rgb, r, g, b}, attrs: [:bold])
      nil -> Style.new(attrs: [:bold])
    end
  end

  # The dialog floats centered above the composed screen; 1-based overlay
  # coordinates are Layout rects (0-based) + 1.
  defp overlay_dialog(frame, %{phase: :dialog} = state) do
    {width, height} = state.dimensions
    dialog_width = width |> min(56) |> max(24)
    dialog_height = 5
    x = div(max(width - dialog_width, 0), 2)
    y = div(max(height - dialog_height, 0), 2)

    Frame.overlay(
      frame,
      AlertDialog.view(state.dialog, {dialog_width, dialog_height}),
      x + 1,
      y + 1
    )
  end

  defp overlay_dialog(frame, _state), do: frame

  # Toasts stack bottom-right, newest nearest the footer, and are clipped by
  # the screen bounds like every other overlay.
  defp overlay_toasts(frame, state) do
    {width, height} = state.dimensions
    toast_width = min(40, max(width - 2, 1))

    state.toasts.toasts
    |> Enum.with_index()
    |> Enum.reduce(frame, fn {toast, index}, acc ->
      y = height - 3 * (index + 1)

      if y >= 0 do
        Frame.overlay(
          acc,
          TermUI.Widget.Toast.view(toast, {toast_width, 3}),
          width - toast_width,
          y + 1
        )
      else
        acc
      end
    end)
  end
end
