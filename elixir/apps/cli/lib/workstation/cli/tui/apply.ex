defmodule Workstation.CLI.TUI.Apply do
  @moduledoc """
  The §5 apply screen: header (destination + generation), capability table
  (id / operation / target, cursor keys), footer key-hints (≤ 40 columns),
  confirm dialog (`a`), animated apply with Progress 0→100 (`y`), token-
  guarded success/error Toast, cancel (`n`/Escape), quit (`q`).

  The screen owns the INTERACTION contract only. The apply itself is the
  `:executor` callback invoked once on confirm: production runs wire
  `Workstation.CLI.TUI.Executor` — the daemon-orchestrated path (b8), which
  serializes through the daemon's apply lock and answers `not_graduated`
  until the engine applier graduates — so an unconfigured screen can render
  and confirm but has no mutation path at all (`dry_run_executor/1`, pure,
  always `:ok`).

  Progress is theatrical by design: the executor result is known before the
  first tick, and the 0→100 animation keeps the same shape the real applier
  will report (b8), so the screen contract does not churn at graduation.
  Timer ticks carry the run's `make_ref/0` token; late ticks from a
  superseded run are dropped in update/2 instead of corrupting state.
  """

  use TermUI.Elm

  alias TermUI.{Command, Event, Frame, Layout, Style}
  alias TermUI.Widget.{AlertDialog, Helpers, Progress, Table}
  alias TermUI.Widget.Table.Column
  alias TermUI.Widget.Toast.Manager

  alias Workstation.CLI.TUI.Executor
  alias Workstation.CLI.TUI.Theme

  @enforce_keys [
    :destination,
    :generation,
    :entries,
    :table,
    :dialog,
    :toasts,
    :progress,
    :phase,
    :theme,
    :dimensions,
    :executor,
    :tick_ms,
    :toast_ms
  ]
  defstruct [
    :destination,
    :generation,
    :entries,
    :table,
    :dialog,
    :toasts,
    :progress,
    :phase,
    :run,
    :theme,
    :dimensions,
    :executor,
    :tick_ms,
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
          progress: Progress.t(),
          phase: phase(),
          run: %{ref: run_token(), outcome: :ok | {:error, term()}} | nil,
          theme: Theme.colors(),
          dimensions: {pos_integer(), pos_integer()},
          executor: (map() -> :ok | {:error, term()}),
          tick_ms: pos_integer(),
          toast_ms: pos_integer()
        }

  @ticks 10

  # Footer hints stay ≤ 40 display columns; the frame clips anyway, but the
  # budget keeps every hint readable on the smallest supported terminal.
  @ready_footer "a confirm · ↑↓ move · enter select · q quit"
  @dialog_footer "y confirm apply · n/esc cancel · q quit"
  @done_footer "q quit"
  @header_rows 2

  @doc """
  Default executor: the pure pre-graduation stand-in. Production runs use
  `Workstation.CLI.TUI.Executor` (the daemon-orchestrated path, b8 wiring);
  the pure stand-in stays the default so an accidental unconfigured run can
  never mutate anything.
  """
  @spec dry_run_executor(map()) :: :ok
  def dry_run_executor(_request), do: :ok

  @doc """
  Table rows for the plan body's entries, in canonical engine order. The row
  id is the entry's `source_name` — the identity key the production entry
  view carries (the recorded golden projection spells the same value `name`).
  """
  @spec entries_from_plan(map()) :: [map()]
  def entries_from_plan(plan) do
    plan
    |> get_in(["plan", "entries"])
    |> case do
      entries when is_list(entries) -> entries
      _other -> []
    end
    |> Enum.map(fn entry ->
      %{
        "id" => entry["source_name"],
        "operation" => entry["operation"] || entry["type"],
        "target" => entry["target"]
      }
    end)
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
      progress: Progress.init(value: 0, label: "apply"),
      phase: :ready,
      theme: Keyword.fetch!(opts, :theme),
      dimensions: Keyword.fetch!(opts, :dimensions),
      executor: Keyword.get(opts, :executor, &Executor.apply_executor/1),
      tick_ms: Keyword.get(opts, :tick_ms, 100),
      toast_ms: Keyword.get(opts, :toast_ms, 5_000)
    }

    state
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

  def update({:text, "q"}, state), do: {state, [Command.shutdown(:normal)]}

  def update({:apply_tick, ref}, %{phase: :running, run: %{ref: ref}} = state) do
    value = min(state.progress.value + div(100, @ticks), 100)
    progress = Progress.set_value(state.progress, value)

    if value < 100 do
      {%{state | progress: progress}, [Command.timer(state.tick_ms, {:apply_tick, ref})]}
    else
      finish_run(%{state | progress: progress})
    end
  end

  # A tick whose token does not match the live run (cancelled/superseded) is
  # dropped: token-guarding is what keeps timer effects from acting on stale
  # state once the run lifecycle can be interrupted.
  def update({:apply_tick, _stale_ref}, state), do: state

  def update({:term_ui_toast_expire, _manager_id, _toast_id, _token} = expire, state),
    do: %{state | toasts: Manager.expire(state.toasts, expire)}

  def update({:dialog_cancel, :cancel}, state), do: %{state | phase: :ready}

  def update({:resize, width, height}, state), do: %{state | dimensions: {width, height}}

  def update(_message, state), do: state

  @impl TermUI.Elm
  def view(state) do
    {width, height} = state.dimensions

    [header, body, footer] =
      Layout.column(Layout.new({width, height}), [@header_rows, :fill, 1])

    Helpers.frame([], {width, height})
    |> Helpers.compose(header, fn dims -> header_frame(state, dims) end)
    |> Helpers.compose(body, fn dims -> Table.view(state.table, dims) end)
    |> Helpers.compose(footer, fn dims -> footer_frame(state, dims) end)
    |> overlay_dialog(state)
    |> overlay_toasts(state)
  end

  ## run lifecycle

  defp start_run(state) do
    ref = make_ref()

    # The executor receives the wire-shaped request, not the raw rows: the
    # daemon op surface (apply.run) is the graduation contract, so the screen
    # hands over exactly what the protocol schema validates.
    run = %{ref: ref, outcome: state.executor.(%{"generation" => state.generation, "entries" => state.entries})}

    {%{state | phase: :running, run: run, progress: Progress.set_value(state.progress, 0)},
     [Command.timer(state.tick_ms, {:apply_tick, ref})]}
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

    {%{state | phase: :done, toasts: toasts}, commands}
  end

  ## rendering

  defp columns do
    [
      Column.new("id", "CAPABILITY", width: 30),
      Column.new("operation", "OPERATION", width: 12),
      Column.new("target", "TARGET")
    ]
  end

  defp header_frame(state, dims) do
    Helpers.frame(
      [
        [accent_text(state, "workstation apply"), "  #{state.destination}"],
        "generation #{state.generation} · #{length(state.entries)} change(s)"
      ],
      dims
    )
  end

  defp footer_frame(%{phase: :running} = state, dims), do: Progress.view(state.progress, dims)
  defp footer_frame(%{phase: :dialog}, dims), do: Helpers.frame([@dialog_footer], dims)
  defp footer_frame(%{phase: :done}, dims), do: Helpers.frame([@done_footer], dims)
  defp footer_frame(_state, dims), do: Helpers.frame([@ready_footer], dims)

  defp accent_text(state, text) do
    case Theme.to_term_ui_color(state.theme[:accent]) do
      {:rgb, r, g, b} -> {text, Style.new(fg: {:rgb, r, g, b}, attrs: [:bold])}
      nil -> {text, Style.new(attrs: [:bold])}
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
