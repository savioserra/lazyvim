defmodule Workstation.CLI.TUI.Update do
  @moduledoc """
  The §5 update screen: the lifecycle step list `pull → bootstrap → apply →
  sync → verify`, one status per step, abort on first failure (the update
  semantics of docs/capabilities.md: a failed step leaves the remaining
  steps skipped, never partially executed).

  The chain is ONE daemon op (`update.run` over the full `steps`
  sub-chain): the daemon owns the locks, the step sequencing and the
  handoff; the screen RENDERS the op's event frames — `step.started`,
  `step.done`, `run.finished` — as row transitions, it never drives steps
  itself. The op task runs outside the Elm loop (`Command.async/2`); each
  event frame is queued back into the loop with
  `TermUI.send_message/2`, and the op's eventual result arrives as the
  async completion. Every transition therefore resolves through pure
  `update/2`, which is what lets the deterministic backend replay an
  entire run from a recorded event list.

  Run token: a `make_ref/0` rides in every chain message and event; a
  message whose token does not match the live run is dropped, so a
  re-launched chain can never interleave with a previous one.

  Abort semantics (docs/capabilities.md): `x` forwards `op.abort` with the
  stream's `op_ref`; the daemon cancels the chain at its NEXT STEP
  BOUNDARY — never mid-step — and reports the `"aborted"` outcome, and the
  still-pending steps render skipped. `q` during a run DETACHES: the
  daemon keeps the lock and finishes (or aborts) the chain without a
  viewer; a later `workstation update` re-attaches to the journal's state.

  Anatomy: ONE full-screen rounded box — `update` island + destination in
  the top border, step + failure counters in the top-right islands, the
  phase's buttonbar on the bottom border, and the step table inset inside
  the box. The chain is armed by the typed-confirm gate (spec §2.3, the
  same contract as the apply screen): the screen opens idle (`a confirm`
  buttonbar), `a` opens the dialog, the operator types the verb
  (`update`) and Enter starts the chain — a mutating op never fires from
  a bare keystroke.

  The passive availability indicator (supervisor-directed engine scope)
  fires `update.check` asynchronously on open and after every completed
  chain; when the branch is behind, the footer surfaces the accent
  indicator and `u` re-runs the update flow (a fresh chain over the same
  step list).
  """

  use TermUI.Elm

  alias TermUI.{Command, Event, Frame, Layout, Runtime, Style}
  alias TermUI.Widget.{Dialog, Helpers, Table}
  alias TermUI.Widget.Table.Column
  alias TermUI.Widget.Toast.Manager

  alias Workstation.CLI.TUI.{Executor, Shell.Box, Theme, UpdateHint}

  @enforce_keys [
    :destination,
    :steps,
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
    :steps,
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
    :toast_ms,
    # The typed-confirm gate's input buffer (dialog phase only; spec §2.3).
    typed: ""
  ]

  @type phase :: :ready | :dialog | :running | :done
  @type step :: String.t()
  @type run_token :: reference()
  @type op_ref :: String.t() | nil

  # Step rows stay string-keyed maps: they are table rows AND plan-wire
  # shaped payloads (id/status), so the table column lookup works directly.
  @type steps :: [%{optional(String.t()) => String.t()}]

  @type t :: %__MODULE__{
          destination: String.t(),
          steps: steps(),
          table: Table.t(),
          dialog: Dialog.t() | nil,
          toasts: Manager.t(),
          phase: phase(),
          run: %{ref: run_token(), op_ref: op_ref()} | nil,
          theme: Theme.colors(),
          dimensions: {pos_integer(), pos_integer()},
          executor: (map() -> :ok | {:error, term()}),
          check: (() -> {:ok, map()} | {:error, term()}),
          update_hint: UpdateHint.hint() | nil,
          tui_caller: pid() | nil,
          toast_ms: pos_integer(),
          typed: String.t()
        }

  # Footer grammar renders as buttonbar islands (see footer_buttons/1).

  # The typed-confirm verb (spec §2.3): what the operator must type to arm
  # the chain; compared case- and whitespace-insensitively.
  @confirm_verb "update"
  # The buffer cap — comfortably longer than the verb, short enough that a
  # stuck key cannot run the echo out of the dialog.
  @typed_max 16

  @doc "Lifecycle steps in execution order (docs/capabilities.md)."
  @spec steps() :: [step()]
  defdelegate steps(), to: Workstation.Core.Update

  @doc """
  Default executor: the pure pre-graduation stand-in. Production runs use
  `Workstation.CLI.TUI.Executor` (the daemon-orchestrated path); the pure
  stand-in replays a synthetic ok event list so an accidental unconfigured
  run can never mutate anything while still exercising the event path.
  """
  @spec dry_run_executor(map()) :: :ok
  def dry_run_executor(%{"steps" => steps, "events" => events}) when is_list(steps) do
    Enum.each(steps, fn step ->
      events.(%{"type" => "step.started", "step" => step})
      events.(%{"type" => "step.done", "step" => step, "ok" => true, "duration_ms" => 0})
    end)

    events.(%{"type" => "run.finished", "outcome" => "ok"})
    :ok
  end

  def dry_run_executor(_request), do: :ok

  @impl TermUI.Elm
  def init(opts) do
    destination = Keyword.fetch!(opts, :destination)
    steps = Enum.map(steps(), &%{"id" => &1, "status" => "pending"})

    state = %__MODULE__{
      destination: destination,
      steps: steps,
      table: Table.init(rows: steps, columns: columns(), row_id: "id", selection_mode: :none),
      toasts: Manager.new(id: :update_toasts),
      # The chain arms behind the typed-confirm gate (spec §2.3) — the
      # screen boots idle; `a` opens the gate dialog, typing the verb and
      # Enter starts the chain.
      phase: :ready,
      run: nil,
      dialog: confirm_dialog(destination),
      theme: Keyword.fetch!(opts, :theme),
      dimensions: Keyword.fetch!(opts, :dimensions),
      executor: Keyword.get(opts, :executor, &Executor.update_executor/1),
      check: Keyword.get(opts, :check, &Executor.update_check_executor/0),
      update_hint: nil,
      tui_caller: Keyword.get(opts, :tui_caller),
      toast_ms: Keyword.get(opts, :toast_ms, 5_000)
    }

    # The availability check is the init effect (the chain itself waits
    # behind the gate): the indicator consults the daemon without any
    # user input, mirroring `workstation update` semantics.
    {state, check_commands(state)}
  end

  @doc "Same event normalization contract as the apply screen."
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
  def update({:text, "a"}, %{phase: :ready} = state),
    do: %{state | phase: :dialog, typed: ""} |> put_dialog()

  # The dialog's single cancel button is navigable; the screen keeps its
  # own typed-confirm/Escape contract and ignores button activation.
  def update({:key, key}, %{phase: :dialog} = state)
      when key in [:up, :down, :left, :right, :tab] do
    {dialog, _messages} = Dialog.update(Event.key(key), state.dialog)
    %{state | dialog: dialog}
  end

  # Enter is the typed gate: the buffer must BE the verb (case- and
  # whitespace-insensitive) to arm the chain; anything else stays put so a
  # mistyped verb can be corrected in place (backspace) or cancelled.
  def update({:key, :enter}, %{phase: :dialog, typed: typed} = state) do
    if String.downcase(String.trim(typed)) == @confirm_verb do
      start_chain(state)
    else
      state
    end
  end

  def update({:key, :backspace}, %{phase: :dialog} = state) do
    dropped = String.slice(state.typed, 0, max(String.length(state.typed) - 1, 0))
    %{state | typed: dropped} |> put_dialog()
  end

  # Cancel: `n` is reserved even mid-buffer (the footer advertises it),
  # so it must precede the printable-buffer clause.
  def update({:text, "n"}, %{phase: :dialog} = state), do: %{state | phase: :ready, typed: ""}

  # Every printable character feeds the confirm buffer (the verb echo in
  # the dialog); multi-char text events are not keystrokes — ignored.
  def update({:text, ch}, %{phase: :dialog, typed: typed} = state)
      when is_binary(ch) and byte_size(ch) == 1 and ch != "\n" and ch != "\r" and ch != "\t" and
             ch != " " do
    if String.length(typed) < @typed_max do
      %{state | typed: typed <> ch} |> put_dialog()
    else
      state
    end
  end

  def update({:key, :escape}, %{phase: :dialog} = state),
    do: %{state | phase: :ready, typed: ""}

  def update({:dialog_cancel, :cancel}, state), do: %{state | phase: :ready, typed: ""}

  @impl TermUI.Elm
  def update({:update_event, ref, %{"type" => "run.started", "op_ref" => op_ref}},
             %{phase: :running, run: %{ref: ref}} = state) do
    %{state | run: %{state.run | op_ref: op_ref}}
  end

  def update({:update_event, ref, %{"type" => "step.started", "step" => step}},
             %{phase: :running, run: %{ref: ref}} = state) do
    set_status(state, step, "running")
  end

  def update({:update_event, ref, %{"type" => "step.done", "step" => step, "ok" => ok}},
             %{phase: :running, run: %{ref: ref}} = state)
      when is_boolean(ok) do
    status = if ok, do: "ok", else: "failed"
    set_status(state, step, status)
  end

  def update({:update_event, _stale_ref, _event}, state), do: state

  def update({:chain_done, ref, outcome}, %{phase: :running, run: %{ref: ref}} = state) do
    finish_run(state, outcome)
  end

  def update({:chain_done, _stale_ref, _outcome}, state), do: state

  # The check result folds through UpdateHint: only "behind" surfaces,
  # everything else (up_to_date, unknown, transport error) is silent.
  def update({:check_done, verdict}, state) do
    %{state | update_hint: UpdateHint.fold(verdict)}
  end

  # Re-run the update flow from the finished screen: the [u] affordance
  # resets the step list and opens the typed-confirm gate — the re-run is
  # as armed as the first run (only offered while the indicator shows).
  def update({:text, "u"}, %{phase: :done, update_hint: hint} = state) when hint != nil do
    steps = Enum.map(state.steps, &%{&1 | "status" => "pending"})

    %{state | steps: steps, table: Table.set_rows(state.table, steps), phase: :dialog, typed: ""}
    |> put_dialog()
  end

  # Abort: forwards op.abort with the stream token; the daemon settles the
  # chain at its next step boundary and the ordinary event path paints the
  # outcome (a racing finish surfaces as the abort executor's error value,
  # silently dropped here — the chain result carries the verdict).
  def update({:text, "x"}, %{phase: :running, run: %{op_ref: op_ref}} = state)
      when is_binary(op_ref) do
    {state, [Command.async(fn -> Executor.abort_executor(op_ref) end, fn _result -> :noop end)]}
  end

  def update({:text, "q"}, state), do: {state, [Command.shutdown(:normal)]}
  def update(:noop, state), do: state

  def update({:term_ui_toast_expire, _manager_id, _toast_id, _token} = expire, state),
    do: %{state | toasts: Manager.expire(state.toasts, expire)}

  def update({:resize, width, height}, state), do: %{state | dimensions: {width, height}}

  def update(_message, state), do: state

  @impl TermUI.Elm
  def view(state, underlay \\ :none) do
    {width, height} = state.dimensions

    case state.phase do
      phase when phase in [:running, :done] ->
        base = if is_map(underlay), do: underlay, else: Helpers.frame([], {width, height})
        {panel_dims, x, y} = run_rect(width, height)

        panel =
          Helpers.frame([], panel_dims)
          |> Helpers.compose(Layout.new(panel_dims), fn dims -> screen_frame(state, dims) end)

        base
        |> Frame.overlay(panel, x + 1, y + 1)
        |> overlay_toasts(state)

      _ ->
        Helpers.frame([], {width, height})
        |> Helpers.compose(Layout.new({width, height}), fn dims -> screen_frame(state, dims) end)
        |> overlay_dialog(state)
        |> overlay_toasts(state)
    end
  end

  # The gate dialog floats centered above the composed screen; 1-based
  # overlay coordinates are Layout rects (0-based) + 1.
  defp overlay_dialog(frame, %{phase: :dialog} = state) do
    {width, height} = state.dimensions
    dialog_width = width |> min(64) |> max(24)
    dialog_height = 5
    x = div(max(width - dialog_width, 0), 2)
    y = div(max(height - dialog_height, 0), 2)

    Frame.overlay(
      frame,
      Dialog.view(state.dialog, {dialog_width, dialog_height}),
      x + 1,
      y + 1
    )
  end

  defp overlay_dialog(frame, _state), do: frame

  # §1.6: at shell scale the run floats as a boxed step panel over the
  # living dashboard (the shell hands its mirror in as the underlay) —
  # the step stream keeps its box, the dashboard shows around it. Below
  # the float threshold the box keeps the full rect (a compact screen's
  # step list has no ring to spare).
  defp run_rect(width, height) when height < 16 or width < 60,
    do: {{width, height}, 0, 0}

  defp run_rect(width, height), do: {{max(width - 8, 20), max(height - 4, 6)}, 4, 2}

  # The boxed op screen: the step table inset inside one rounded box whose
  # border carries the title, counters, and the phase's buttonbar.
  defp screen_frame(state, {width, height} = dims) do
    box =
      Box.frame([], dims,
        border_style: role_style(state, :chrome),
        title: [
          {" update ", bold_role(state, :accent)},
          {"· ", role_style(state, :chrome)},
          {state.destination <> " ", Style.new()}
        ],
        right: [
          [{"#{length(state.steps)} steps", role_style(state, :chrome)}],
          [{"abort on first failure", role_style(state, :chrome)}]
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
    [[{"updating", bold_role(state, :accent)}]] ++ key_islands(state, x: "abort", q: "detach")
  end

  defp footer_buttons(%{phase: :dialog} = state),
    do: key_islands(state, enter: "confirm update", n: "cancel", q: "quit")

  defp footer_buttons(%{phase: :ready, update_hint: hint} = state) when hint != nil do
    key_islands(state, a: "confirm", q: "quit") ++ [[{UpdateHint.text(hint), bold_role(state, :accent)}]]
  end

  defp footer_buttons(%{phase: :ready} = state), do: key_islands(state, a: "confirm", q: "quit")

  defp footer_buttons(%{phase: :done, update_hint: hint} = state) when hint != nil do
    key_islands(state, q: "quit") ++ [[{UpdateHint.text(hint), bold_role(state, :accent)}]]
  end

  defp footer_buttons(%{phase: :done} = state), do: key_islands(state, q: "quit")

  # One island per key: the cap rides the bold accent slot, the label
  # follows the theme's text role — btop's border-button grammar (labels
  # are text-role, never unstyled literals).
  defp key_islands(state, pairs) do
    Enum.map(pairs, fn {cap, label} ->
      [{Atom.to_string(cap), bold_role(state, :accent)}, {" #{label}", role_style(state, :text)}]
    end)
  end

  ## chain

  # ONE daemon op for the whole sub-chain. The events sink queues each
  # frame back into THIS runtime's Elm loop (self() during init/update is
  # the runtime process), token-guarded by the run reference.
  defp start_chain(%{executor: executor, steps: steps} = state) do
    ref = make_ref()
    runtime = self()

    request = %{
      "steps" => Enum.map(steps, & &1["id"]),
      "events" => fn event ->
        Runtime.send_message(runtime, {:update_event, ref, event})
      end
    }

    command =
      Command.async(fn -> executor.(request) end, fn
        {:ok, outcome} -> {:chain_done, ref, outcome}
        {:error, reason} -> {:chain_done, ref, {:error, inspect(reason, pretty: false)}}
      end)

    {%{state | phase: :running, run: %{ref: ref, op_ref: nil}, typed: ""}, [command]}
  end

  ## typed-confirm dialog (spec §2.3)

  # The gate dialog: the echo line (`_` is the caret) and one inert
  # cancel button — YES is armed by the typed verb + Enter, not by button
  # navigation. Rebuilt on every buffer change so the echo is live.
  defp confirm_dialog(_destination, typed \\ "") do
    Dialog.init(
      title: "Confirm update",
      content: [
        "Run the update chain (pull, bootstrap, apply, sync, verify)?",
        "Type #{@confirm_verb} to confirm: #{typed}_"
      ],
      buttons: [%{id: :cancel, label: "cancel (Esc)", message: :dialog_cancel}],
      dismiss_message: :dialog_cancel
    )
  end

  defp put_dialog(%{destination: destination, typed: typed} = state),
    do: %{state | dialog: confirm_dialog(destination, typed)}

  defp finish_run(state, :ok) do
    {toasts, commands} =
      Manager.add_with_timer(state.toasts, "Update completed", :success,
        id: :update_result,
        duration: state.toast_ms
      )

    # A completed chain re-checks availability (the fresh journal may have
    # pulled the remote head): silent unless the branch is still behind.
    {%{state | phase: :done, run: nil, toasts: toasts}, commands ++ check_commands(state)}
  end

  defp finish_run(state, {:error, reason}) do
    # No step name in the toast: the failing step is already marked
    # "failed" in the table, and the toast box clips at 40 columns.
    {toasts, commands} =
      Manager.add_with_timer(state.toasts, "Update failed: #{reason}", :error,
        id: :update_result,
        duration: state.toast_ms
      )

    # Abort-on-first-failure: the daemon never half-runs the tail, so every
    # step it did not settle renders skipped with its original position.
    state = mark_pending_skipped(state)

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

  defp set_status(state, id, status) do
    steps =
      Enum.map(state.steps, fn step ->
        if step["id"] == id do
          %{step | "status" => status}
        else
          step
        end
      end)

    %{state | steps: steps, table: Table.set_rows(state.table, steps)}
  end

  defp mark_pending_skipped(state) do
    steps =
      Enum.map(state.steps, fn step ->
        if step["status"] == "pending", do: %{step | "status" => "skipped"}, else: step
      end)

    %{state | steps: steps, table: Table.set_rows(state.table, steps)}
  end

  ## rendering

  defp columns do
    [
      Column.new("id", "STEP", width: 12),
      Column.new("status", "STATUS", width: 10)
    ]
  end

  defp role_style(state, role), do: %Style{fg: Theme.to_term_ui_color(state.theme[role])}

  defp bold_role(state, role) do
    case Theme.to_term_ui_color(state.theme[role]) do
      {:rgb, r, g, b} -> Style.new(fg: {:rgb, r, g, b}, attrs: [:bold])
      nil -> Style.new(attrs: [:bold])
    end
  end

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
