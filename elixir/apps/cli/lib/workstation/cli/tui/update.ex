defmodule Workstation.CLI.TUI.Update do
  @moduledoc """
  The §5 update screen: the lifecycle step list `pull → bootstrap → apply →
  sync → verify`, one status per step, abort on first failure (the update
  semantics of docs/capabilities.md: a failed step leaves the remaining
  steps skipped, never partially executed).

  The chain is driven as self-messages (`Command.message/1`) so every step
  transition resolves through pure `update/2` — no process state outside
  the Elm loop, which is what makes the deterministic backend able to
  replay an entire update deterministically. The step executor is the same
  strangler seam as the apply screen: production runs wire
  `Workstation.CLI.TUI.Executor` — the daemon-orchestrated path (b8), one
  lifecycle op per chain link, abort on first daemon refusal — while
  `dry_run_executor/1` remains the pure, always-`:ok` default for tests and
  offline runs.

  A run token (`make_ref/0`) rides in every chain message; a message whose
  token does not match the live run is dropped, so a restart of the chain
  can never interleave with a previous one.
  """

  use TermUI.Elm

  alias TermUI.{Command, Event, Frame, Layout, Style}
  alias TermUI.Widget.{Helpers, Table}
  alias TermUI.Widget.Table.Column
  alias TermUI.Widget.Toast.Manager

  alias Workstation.CLI.TUI.Executor
  alias Workstation.CLI.TUI.Theme

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
    :toast_ms
  ]

  @type phase :: :running | :done
  @type step :: String.t()
  @type run_token :: reference()

  # Step rows stay string-keyed maps: they are table rows AND plan-wire
  # shaped payloads (id/status), so the table column lookup works directly.
  @type steps :: [%{optional(String.t()) => String.t()}]

  @type t :: %__MODULE__{
          destination: String.t(),
          steps: steps(),
          table: Table.t(),
          toasts: Manager.t(),
          phase: phase(),
          run: %{ref: run_token()} | nil,
          theme: Theme.colors(),
          dimensions: {pos_integer(), pos_integer()},
          executor: (map() -> :ok | {:error, term()}),
          toast_ms: pos_integer()
        }

  @ready_footer "q quit"
  @running_footer "updating · q quit"
  @header_rows 2

  @doc "Lifecycle steps in execution order (docs/capabilities.md)."
  @spec steps() :: [step()]
  defdelegate steps(), to: Workstation.Core.Update

  @doc """
  Default executor: the pure pre-graduation stand-in. Production runs use
  `Workstation.CLI.TUI.Executor` (the daemon-orchestrated path, b8 wiring);
  the pure stand-in stays the default so an accidental unconfigured run can
  never mutate anything.
  """
  @spec dry_run_executor(map()) :: :ok
  def dry_run_executor(_request), do: :ok

  @impl TermUI.Elm
  def init(opts) do
    destination = Keyword.fetch!(opts, :destination)
    steps = Enum.map(steps(), &%{"id" => &1, "status" => "pending"})
    ref = make_ref()

    state = %__MODULE__{
      destination: destination,
      steps: steps,
      table: Table.init(rows: steps, columns: columns(), row_id: "id", selection_mode: :none),
      toasts: Manager.new(id: :update_toasts),
      phase: :running,
      run: %{ref: ref},
      theme: Keyword.fetch!(opts, :theme),
      dimensions: Keyword.fetch!(opts, :dimensions),
      executor: Keyword.get(opts, :executor, &Executor.update_executor/1),
      toast_ms: Keyword.get(opts, :toast_ms, 5_000)
    }

    # The first chain link is an init effect: the step list starts moving
    # without any user input, mirroring `workstation update` semantics.
    {state, [Command.message({:run_step, ref})]}
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
  def update({:run_step, ref}, %{phase: :running, run: %{ref: ref}} = state) do
    case Enum.find(state.steps, &(&1["status"] == "pending")) do
      nil -> finish_run(state, :ok)
      step -> run_step(state, step)
    end
  end

  def update({:run_step, _stale_ref}, state), do: state

  def update({:text, "q"}, state), do: {state, [Command.shutdown(:normal)]}

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

  defp run_step(state, step) do
    id = step["id"]

    # Wire-shaped request per chain link: the daemon op surface (update.run)
    # is the graduation contract, so the chain hands over exactly what the
    # protocol schema validates.
    case state.executor.(%{"step" => id}) do
      :ok ->
        state = set_status(state, id, "ok")

        case Enum.any?(state.steps, &(&1["status"] == "pending")) do
          true -> {state, [Command.message({:run_step, state.run.ref})]}
          false -> finish_run(state, :ok)
        end

      {:error, reason} ->
        # Abort on first failure: the failing step is marked, everything
        # still pending is skipped — the remaining steps never half-run.
        state =
          state
          |> set_status(id, "failed")
          |> mark_pending_skipped()

        finish_run(state, {:error, {id, reason}})
    end
  end

  defp finish_run(state, :ok) do
    {toasts, commands} =
      Manager.add_with_timer(state.toasts, "Update completed", :success,
        id: :update_result,
        duration: state.toast_ms
      )

    {%{state | phase: :done, run: nil, toasts: toasts}, commands}
  end

  defp finish_run(state, {:error, {_id, reason}}) do
    # No step name in the toast: the failing step is already marked
    # "failed" in the table, and the toast box clips at 40 columns.
    {toasts, commands} =
      Manager.add_with_timer(state.toasts, "Update failed: #{reason}", :error,
        id: :update_result,
        duration: state.toast_ms
      )

    {%{state | phase: :done, run: nil, toasts: toasts}, commands}
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
