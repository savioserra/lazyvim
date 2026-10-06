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

  The passive availability indicator (supervisor-directed engine scope)
  fires `update.check` asynchronously on open and after every completed
  chain; when the branch is behind, the footer surfaces the accent
  indicator and `u` re-runs the update flow (a fresh chain over the same
  step list).
  """

  use TermUI.Elm

  alias TermUI.{Command, Event, Frame, Layout, Runtime, Style}
  alias TermUI.Widget.{Helpers, Table}
  alias TermUI.Widget.Table.Column
  alias TermUI.Widget.Toast.Manager

  alias Workstation.CLI.TUI.{Executor, Theme, UpdateHint}

  @enforce_keys [
    :destination,
    :steps,
    :table,
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

  @type phase :: :running | :done
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
          toasts: Manager.t(),
          phase: phase(),
          run: %{ref: run_token(), op_ref: op_ref()} | nil,
          theme: Theme.colors(),
          dimensions: {pos_integer(), pos_integer()},
          executor: (map() -> :ok | {:error, term()}),
          check: (() -> {:ok, map()} | {:error, term()}),
          update_hint: UpdateHint.hint() | nil,
          tui_caller: pid() | nil,
          toast_ms: pos_integer()
        }

  @ready_footer "q quit"
  @running_footer "updating · x abort · q detach"
  @header_rows 2

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
      phase: :running,
      run: nil,
      theme: Keyword.fetch!(opts, :theme),
      dimensions: Keyword.fetch!(opts, :dimensions),
      executor: Keyword.get(opts, :executor, &Executor.update_executor/1),
      check: Keyword.get(opts, :check, &Executor.update_check_executor/0),
      update_hint: nil,
      tui_caller: Keyword.get(opts, :tui_caller),
      toast_ms: Keyword.get(opts, :toast_ms, 5_000)
    }

    # The chain and the availability check are init effects: the step list
    # starts moving and the indicator consults the daemon without any user
    # input, mirroring `workstation update` semantics.
    {state, chain_commands} = start_chain(state)
    {state, chain_commands ++ check_commands(state)}
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

  # Re-run the update flow from the finished screen: only offered while
  # the indicator is showing (the `[u]` affordance), never while running.
  def update({:text, "u"}, %{phase: :done, update_hint: hint} = state) when hint != nil do
    steps = Enum.map(state.steps, &%{&1 | "status" => "pending"})

    state = %__MODULE__{
      state
      | steps: steps,
        table: Table.set_rows(state.table, steps),
        phase: :running,
        run: nil
    }

    {state, commands} = start_chain(state)
    {state, commands}
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
  def view(state) do
    {width, height} = state.dimensions

    [header, body, footer] =
      Layout.column(Layout.new({width, height}), [@header_rows, :fill, 1])

    Helpers.frame([], {width, height})
    |> Helpers.compose(header, fn dims -> header_frame(state, dims) end)
    |> Helpers.compose(body, fn dims -> Table.view(state.table, dims) end)
    |> Helpers.compose(footer, fn dims -> footer_frame(state, dims) end)
    |> overlay_toasts(state)
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

    {%{state | phase: :running, run: %{ref: ref, op_ref: nil}}, [command]}
  end

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

  defp header_frame(state, dims) do
    Helpers.frame(
      [
        [accent_text(state, "workstation update"), "  #{state.destination}"],
        "#{length(state.steps)} steps · abort on first failure"
      ],
      dims
    )
  end

  defp footer_frame(%{phase: :running}, dims), do: Helpers.frame([@running_footer], dims)

  defp footer_frame(%{phase: :done, update_hint: hint} = state, dims) when hint != nil do
    # The indicator rides the idle footer as an accent segment (the locked
    # wording), followed by the ordinary quit affordance.
    Helpers.frame([[@ready_footer, "  ", accent_text(state, UpdateHint.text(hint))]], dims)
  end

  defp footer_frame(_state, dims), do: Helpers.frame([@ready_footer], dims)

  defp accent_text(state, text) do
    case Theme.to_term_ui_color(state.theme[:accent]) do
      {:rgb, r, g, b} -> {text, Style.new(fg: {:rgb, r, g, b}, attrs: [:bold])}
      nil -> {text, Style.new(attrs: [:bold])}
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
