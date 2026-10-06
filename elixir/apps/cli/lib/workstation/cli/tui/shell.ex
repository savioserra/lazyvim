defmodule Workstation.CLI.TUI.Shell do
  @moduledoc """
  The workstation TUI application shell — the bare-verb home. One Elm root
  (the same `TermUI.Elm` contract as the apply/update screens) owning the
  global chrome: a header (destination), a tab strip (home, capabilities,
  status, plan, diff, daemon, help), the active tab's body and a footer
  with the global keys. Every verb is reachable from it:

    * read views (status/plan/diff) render the canonical
      `Workstation.CLI.Render` text in a scrollable pane — the TUI cannot
      disagree with the verb output because both render the same function;
    * the capabilities tab is the domain-grouped browser over
      `Workstation.CLI.Capabilities.group/1` (rollups first, drill-down
      explicit — the same fold the `workstation capabilities` verb uses);
    * the daemon tab reports daemon health from a live `status.run` probe
      (a read — never a mutation);
    * `a` / `u` open the apply/update screens INSIDE the app: the shell
      embeds `Workstation.CLI.TUI.Apply` / `.Update` below the same tab
      strip, reserving only `q` (leave the screen — a running op keeps
      running daemon-side, the detach semantics of the standalone screen)
      and the apply screen's `[u]` handoff, which swaps to the update
      screen instead of exiting to the CLI process.

  All reads go through the client (one `DaemonClient.call` per wire, the
  same ops the verbs send); the daemon is the only mutation engine — the
  shell never mutates anything itself, and the embedded screens speak the
  identical executor contract as standalone. The `:load`, `:executor`,
  `:update_executor` and `:check` seams are injected funs, so tests replay
  fixed wire/event streams with no daemon involved (deterministic replay).

  Data states are explicit per tab: loading (probe in flight), data,
  error, and the daemon-disconnected shape (transport failure wording
  surfaced with the recovery hint). Keys are documented in the help tab.
  """

  use TermUI.Elm

  alias TermUI.{Command, Event, Layout, Style}
  alias TermUI.Widget.Helpers

  alias Workstation.CLI.Capabilities
  alias Workstation.CLI.DaemonClient
  alias Workstation.CLI.Render
  alias Workstation.CLI.TUI.{Apply, Executor, Theme, Update, UpdateHint}
  alias Workstation.CLI.TUI.Shell.{CapabilitiesBrowser, Help, TextView}

  @read_timeout_ms 120_000

  ## production entry

  @doc """
  Router entry for the bare `workstation` verb once the daemon is
  confirmed healthy (`Shell.DaemonEntry`): resolve the theme from the
  destination home's daemon (base palette fallback) and run this shell on
  the TTY backend. `TermUI` injects `:dimensions` at init.
  """
  def run(opts) do
    home = Keyword.fetch!(opts, :home)

    Workstation.CLI.TUI.run(__MODULE__,
      destination: home,
      appearance: Keyword.get(opts, :appearance, :dark)
    )
  end

  # Tab order is the strip order; the digit keys address it 1-based.
  @tabs [
    {:home, "home"},
    {:capabilities, "capabilities"},
    {:status, "status"},
    {:plan, "plan"},
    {:diff, "diff"},
    {:daemon, "daemon"},
    {:help, "help"}
  ]

  @type load_state :: nil | :loading | {:ok, map()} | {:error, String.t()}
  @type tab_id :: :home | :capabilities | :status | :plan | :diff | :daemon | :help
  @type op_screen :: {:apply, Apply.t()} | {:update, Update.t()}

  defstruct [
    :destination,
    :theme,
    :dimensions,
    :tab,
    :last_data_tab,
    :cache,
    :load,
    :caps,
    :caps_env,
    :text_views,
    :op,
    :executor,
    :update_executor,
    :check,
    :update_hint,
    :toast_ms
  ]

  @type t :: %__MODULE__{
          destination: String.t(),
          theme: Theme.colors(),
          dimensions: {pos_integer(), pos_integer()},
          tab: tab_id(),
          last_data_tab: tab_id(),
          cache: %{atom() => load_state()},
          load: (atom() -> {:ok, map()} | {:error, String.t()}),
          caps: CapabilitiesBrowser.t(),
          caps_env: map() | nil,
          text_views: %{atom() => TextView.t()},
          op: op_screen() | nil,
          executor: (map() -> :ok | {:error, term()}),
          update_executor: (map() -> :ok | {:error, term()}),
          check: (() -> {:ok, map()} | {:error, term()}),
          update_hint: UpdateHint.hint() | nil,
          toast_ms: pos_integer()
        }

  @doc """
  Default loader: the exact read path of the verbs — one daemon op per
  wire (`status.run` / `plan.run` / `diff.run`), daemon transport failures
  folded to the flat `"<tag>: <message>"` string the shell classifies.
  """
  @spec daemon_load(atom(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def daemon_load(command, destination) do
    op = Map.fetch!(%{status: "status.run", plan: "plan.run", diff: "diff.run"}, command)

    case DaemonClient.call(op, %{}, home: destination, timeout_ms: @read_timeout_ms) do
      {:ok, wire} ->
        {:ok, wire}

      {:error, {tag, message}} when is_atom(tag) ->
        {:error, "#{tag}: #{message}"}

      {:error, {code, message}} when is_binary(code) ->
        {:error, "#{code}: #{message}"}

      {:error, code, message} ->
        {:error, "#{code}: #{message}"}
    end
  end

  @impl TermUI.Elm
  def init(opts) do
    state = %__MODULE__{
      destination: Keyword.fetch!(opts, :destination),
      theme: Keyword.fetch!(opts, :theme),
      dimensions: Keyword.fetch!(opts, :dimensions),
      tab: :home,
      last_data_tab: :home,
      cache: %{},
      load: Keyword.get(opts, :load, &daemon_load(&1, Keyword.fetch!(opts, :destination))),
      caps: CapabilitiesBrowser.init(nil),
      caps_env: nil,
      text_views: %{},
      op: nil,
      executor: Keyword.get(opts, :executor, &Executor.apply_executor/1),
      update_executor: Keyword.get(opts, :update_executor, &Executor.update_executor/1),
      check: Keyword.get(opts, :check, &Executor.update_check_executor/0),
      update_hint: nil,
      toast_ms: Keyword.get(opts, :toast_ms, 5_000)
    }

    # Boot effects: the home tab's three reads and the passive
    # availability probe — all asynchronous; the first frame paints
    # immediately in the loading state.
    {state, wire_commands} = load_commands(state, [:status, :plan, :diff], false)
    {state, wire_commands ++ check_commands(state)}
  end

  @doc "Same event normalization contract as the apply/update screens."
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
  ## -- op mode: the embedded screen owns the keyboard --------------------

  # `q` leaves the screen (the standalone screen's quit semantics): a
  # running op keeps running daemon-side — the daemon owns the lock and
  # the journal records the outcome; the shell returns home and re-reads.
  # op is a {kind, sub} tuple; the nil case falls to the quit clause —
  # a bare `op` pattern would also bind nil and make q unquit-able.
  def update({:text, "q"}, %{op: op} = state) when not is_nil(op) do
    close_op(state)
  end

  # q on a data tab quits the app (the footer's documented quit key).
  def update({:text, "q"}, state), do: {state, [Command.shutdown()]}

  # The apply screen's `[u]` handoff, kept INSIDE the app: the same guard
  # as the screen's own clause (idle + indicator showing), but instead of
  # handing off to the CLI process it swaps to the update screen.
  def update({:text, "u"}, %{op: {:apply, %Apply{phase: phase, update_hint: hint}}} = state)
      when phase in [:ready, :done] and hint != nil do
    open_update(state)
  end

  # Resize updates the shell AND the embedded screen (cropped to the body
  # rect — the screens lay themselves out purely from dimensions).
  def update({:resize, width, height}, %{op: {kind, sub}} = state) do
    state = %{state | dimensions: {width, height}}
    {body_width, body_height} = body_dims(state)

    {sub, _commands} = forward(op_module(kind), {:resize, body_width, body_height}, sub)
    %{state | op: {kind, sub}}
  end

  # Tabs mode: resize only reflows (the runtime re-renders right after
  # the dispatch). It must NOT route into the active view — the text
  # panes re-clip at render time, and a routed resize used to clobber
  # an unstored view with an empty one (blank help/read panes).
  def update({:resize, width, height}, %{op: nil} = state),
    do: %{state | dimensions: {width, height}}

  def update(message, %{op: {kind, sub}} = state) do
    {sub, commands} = forward(op_module(kind), message, sub)
    {%{state | op: {kind, sub}}, commands}
  end

  ## -- tabs mode ----------------------------------------------------------

  def update({:text, digit}, state) when digit in ~w(1 2 3 4 5 6 7) do
    {tab_id, _label} = Enum.at(@tabs, String.to_integer(digit) - 1)
    switch_tab(tab_id, state)
  end

  # On the capabilities tab the arrows drill (the browser's documented
  # expand/collapse keys) and backspace pops one drill level; every
  # other tab keeps ←/→ for tab switching (digits always switch).
  def update({:key, arrow}, %{tab: :capabilities} = state) when arrow in [:left, :right] do
    route({:key, arrow}, state)
  end

  def update({:key, :backspace}, %{tab: :capabilities} = state) do
    route({:key, :backspace}, state)
  end

  def update({:key, :left}, state), do: step_tab(state, -1)
  def update({:key, :right}, state), do: step_tab(state, 1)

  def update({:text, "?"}, %{tab: :help} = state), do: switch_tab(state.last_data_tab, state)
  def update({:text, "?"}, state), do: switch_tab(:help, state)

  # r refreshes the active tab's reads — force reload even when cached.
  def update({:text, "r"}, state) do
    {state, commands} = load_commands(state, wires_needed(state.tab), true)
    {state, commands}
  end

  # a applies the current plan from home — the plan the shell already
  # loaded; the embedded screen applies exactly what was rendered.
  def update({:text, "a"}, %{tab: :home, cache: %{plan: {:ok, plan}}} = state) do
    open_apply(plan, state)
  end

  def update({:text, "a"}, state), do: state

  def update({:text, "u"}, %{tab: :home, update_hint: hint} = state) when hint != nil do
    open_update(state)
  end

  def update({:text, "u"}, state), do: state

  # Wire results land in the cache and refresh the derived views.
  def update({:wire_loaded, command, result}, state) do
    state =
      %{state | cache: Map.put(state.cache, command, result)}
      |> refresh_derived(command, result)

    {state, []}
  end

  # The shell's OWN availability probe (the embedded screens run theirs
  # against the same executor; the message shapes do not collide because
  # the shell prefixes its token).
  def update({:shell_check_done, verdict}, state) do
    %{state | update_hint: UpdateHint.fold(verdict)}
  end

  # Scroll / browser keys route by tab; every tab's view ignores the
  # messages that are not its own.
  def update(message, state), do: route(message, state)

  # state.tab is a tab id (atom), not an index: wrap by index arithmetic
  # over @tabs.
  defp step_tab(%{tab: tab} = state, step) do
    count = length(@tabs)
    index = Enum.find_index(@tabs, fn {id, _} -> id == tab end) || 0
    {tab_id, _label} = Enum.at(@tabs, Integer.mod(index + step, count))
    switch_tab(tab_id, state)
  end

  @impl TermUI.Elm
  def view(state) do
    {width, height} = state.dimensions

    heights =
      if state.op do
        # In op mode the embedded screen renders its own footer; the shell
        # keeps only the header and the tab strip (which shows where you
        # are: the op screen's pseudo-tab is highlighted).
        [1, 1, :fill]
      else
        [1, 1, :fill, 1]
      end

    [header, strip, body | rest] = Layout.column(Layout.new({width, height}), heights)
    footer = List.first(rest)

    frame = Helpers.frame([], {width, height})

    frame
    |> Helpers.compose(header, &header_frame(state, &1))
    |> Helpers.compose(strip, &strip_frame(state, &1))
    |> Helpers.compose(body, &body_frame(state, &1))
    |> compose_footer(footer, state)
  end

  # op-nil first: a bare %{op: _op} pattern would bind nil and swallow
  # the normal footer.
  defp compose_footer(frame, footer, %{op: nil} = state),
    do: Helpers.compose(frame, footer, &footer_frame(state, &1))

  defp compose_footer(frame, _footer, %{op: _op}), do: frame

  ## tab switching + data loading

  defp switch_tab(tab_id, state) do
    last_data_tab = if tab_id == :help, do: state.last_data_tab, else: tab_id

    state = %{state | tab: tab_id, last_data_tab: last_data_tab}
    {state, commands} = load_commands(state, wires_needed(tab_id), false)
    {state, commands}
  end

  defp wires_needed(:home), do: [:status, :plan, :diff]
  defp wires_needed(:capabilities), do: [:status, :plan]
  defp wires_needed(:status), do: [:status]
  defp wires_needed(:plan), do: [:plan]
  defp wires_needed(:diff), do: [:diff]
  defp wires_needed(:daemon), do: [:status]
  defp wires_needed(:help), do: []

  # Fire one async load per wire that is not already loaded (or all of
  # them on a forced refresh) and mark them loading.
  defp load_commands(%{cache: cache, load: load} = state, wires, force?) do
    # Enum.flat_map_reduce's fun answers {mapped_list, acc} — the list
    # first — and the call itself returns {list, acc}.
    {commands, cache} =
      Enum.flat_map_reduce(wires, cache, fn wire, cache ->
        current = Map.get(cache, wire)

        if not force? and match?({:ok, _}, current) do
          {[], cache}
        else
          # Total mapper (a raising load degrades to an error state, never
          # takes the loop down) that unwraps the runtime's {:ok, _}
          # envelope: the cache stores the loader's own {:ok, wire} |
          # {:error, reason} shape.
          command =
            Command.async(fn -> load.(wire) end, fn
              {:ok, value} -> {:wire_loaded, wire, value}
              {:error, reason} -> {:wire_loaded, wire, {:error, reason}}
            end)

          {[command], Map.put(cache, wire, :loading)}
        end
      end)

    {%{state | cache: cache}, commands}
  end

  # Derived views refresh as their wires land: the rendered read text
  # (status/plan/diff) and the grouped capabilities envelope (status+plan).
  defp refresh_derived(state, command, {:ok, wire}) when command in [:status, :plan, :diff] do
    text_view = TextView.init(render_text(command, wire))
    state = put_in(state.text_views[command], text_view)

    if command in [:status, :plan], do: refresh_caps(state), else: state
  end

  defp refresh_derived(state, command, {:error, _message}) when command in [:status, :plan] do
    refresh_caps(state)
  end

  defp refresh_derived(state, _command, _result), do: state

  defp refresh_caps(state) do
    with {:ok, status} <- Map.get(state.cache, :status),
         {:ok, plan} <- Map.get(state.cache, :plan) do
      envelope = Capabilities.group(%{"status" => status, "plan" => plan})
      %{state | caps_env: envelope, caps: CapabilitiesBrowser.set_envelope(state.caps, envelope)}
    else
      _other -> state
    end
  end

  defp render_text(:status, wire), do: Render.core_status(wire)
  defp render_text(:plan, wire), do: Render.core_plan(wire)
  defp render_text(:diff, wire), do: Render.core_diff(wire)

  defp check_commands(state) do
    [
      Command.async(state.check, fn
        {:ok, result} -> {:shell_check_done, result}
        {:error, reason} -> {:shell_check_done, {:error, inspect(reason, pretty: false)}}
      end)
    ]
  end

  ## op screens (embedded apply/update)

  defp op_module(:apply), do: Apply
  defp op_module(:update), do: Update

  defp forward(module, message, sub) do
    case module.update(message, sub) do
      {sub, commands} -> {sub, commands}
      sub -> {sub, []}
    end
  end

  defp open_apply(plan, state) do
    {sub, commands} =
      Apply.init(
        destination: state.destination,
        plan: plan,
        theme: state.theme,
        dimensions: body_dims(state),
        executor: state.executor,
        check: state.check,
        toast_ms: state.toast_ms
      )

    {%{state | op: {:apply, sub}}, commands}
  end

  defp open_update(state) do
    {sub, commands} =
      Update.init(
        destination: state.destination,
        theme: state.theme,
        dimensions: body_dims(state),
        executor: state.update_executor,
        check: state.check,
        toast_ms: state.toast_ms
      )

    {%{state | op: {:update, sub}}, commands}
  end

  # Leaving an op screen returns home and re-reads: an apply may have
  # changed the world (or the daemon may still hold the lock — the reads
  # report that honestly).
  defp close_op(state) do
    state = %{state | op: nil, tab: :home, last_data_tab: :home}
    {state, commands} = load_commands(state, wires_needed(:home), true)
    {state, commands}
  end

  defp body_dims(%{dimensions: {_width, height}} = state) do
    # Body rect of the op-mode layout ([1, 1, :fill] — no shell footer).
    # Layout.column answers a LIST of rects.
    [_header, _strip, body] =
      Layout.column(Layout.new(state.dimensions), [1, 1, max(height - 2, 1)])

    {elem(body, 2), elem(body, 3)}
  end

  ## keyboard routing by tab

  # Scroll / browser keys route by tab; every tab's view ignores the
  # messages that are not its own. Help stores its (static) view on
  # first touch so scroll keys work from the first keypress; read tabs
  # get their views from refresh_derived when the wire lands.
  defp route(message, %{tab: :help, text_views: views} = state) do
    view = Map.get(views, :help) || TextView.init(Enum.join(Help.lines(), "\n"))
    %{state | text_views: Map.put(views, :help, TextView.update(message, view))}
  end

  defp route(message, %{tab: tab, text_views: views} = state)
       when tab in [:status, :plan, :diff] do
    # Only an EXISTING view scrolls: synthesizing an empty one here would
    # clobber the pane that refresh_derived is about to fill.
    case Map.get(views, tab) do
      nil -> state
      view -> %{state | text_views: Map.put(views, tab, TextView.update(message, view))}
    end
  end

  defp route(message, %{tab: :capabilities} = state) do
    %{state | caps: CapabilitiesBrowser.update(message, state.caps)}
  end

  defp route(_message, state), do: state

  ## rendering

  defp header_frame(state, {width, height}) do
    accent = accent_style(state)

    Helpers.frame(
      [[{"workstation", accent}, " — #{state.destination}"]],
      {width, height}
    )
  end

  defp strip_frame(state, {width, height}) do
    entries =
      if state.op do
        Enum.map(@tabs, fn {id, label} -> {id, label, false} end) ++
          [{op_tab_id(state.op), op_tab_label(state.op), true}]
      else
        Enum.map(@tabs, fn {id, label} -> {id, label, false} end)
      end

    accent = accent_style(state)
    dim = Style.new(fg: :bright_black)

    spans =
      entries
      |> Enum.with_index()
      |> Enum.flat_map(fn {{id, label, active}, index} ->
        text = "#{index + 1} #{label}"

        style =
          cond do
            active or id == state.tab -> accent
            true -> dim
          end

        [{text, style}, {"  ", Style.new()}]
      end)

    Helpers.frame([spans], {width, height})
  end

  defp op_tab_id({:apply, _sub}), do: :apply_op
  defp op_tab_id({:update, _sub}), do: :update_op
  defp op_tab_label({:apply, _sub}), do: "apply"
  defp op_tab_label({:update, _sub}), do: "update"

  defp body_frame(%{op: {kind, sub}}, _dims), do: op_module(kind).view(sub)

  defp body_frame(%{op: nil, tab: :home} = state, dims), do: home_frame(state, dims)
  defp body_frame(%{op: nil, tab: :daemon} = state, dims), do: daemon_frame(state, dims)
  defp body_frame(%{op: nil, tab: :help} = state, dims) do
    # The key reference is longer than most panes: render it as a
    # scrollable text view (↑↓ / pgup/pgdn) so nothing is clipped.
    view = Map.get(state.text_views, :help) || TextView.init(Enum.join(Help.lines(), "\n"))
    TextView.view(view, dims)
  end

  defp body_frame(%{op: nil, tab: tab, text_views: views} = state, dims)
       when tab in [:status, :plan, :diff] do
    case Map.get(state.cache, tab) do
      {:ok, _wire} ->
        TextView.view(Map.get(views, tab) || TextView.init(""), dims)

      {:error, message} ->
        error_frame("#{tab}: #{message_text(message)}", dims)

      _loading ->
        placeholder("loading #{tab} — the daemon is collecting state", dims)
    end
  end

  defp body_frame(%{op: nil, tab: :capabilities} = state, dims) do
    case caps_readiness(state) do
      :ready ->
        CapabilitiesBrowser.view(state.caps, dims, accent_rgb(state))

      {:loading, missing} ->
        placeholder("loading #{Enum.join(missing, ", ")} — the daemon is collecting state", dims)

      {:error, message} ->
        error_frame("capabilities: #{message_text(message)}", dims)
    end
  end

  defp placeholder(line, {width, height}) do
    Helpers.frame([line, "", "retry with r"], {width, height})
  end

  # Read failures split into the transport shape (daemon unreachable —
  # the recovery hint names the start command) and every other failure
  # (the verbatim message; r retries either way).
  defp error_frame(message, {width, height}) do
    text = message_text(message)

    if disconnected?(text) do
      Helpers.frame(
        [
          "daemon unreachable",
          text,
          "",
          "start it with `workstation daemon` — retry with r"
        ],
        {width, height}
      )
    else
      Helpers.frame(["read failed", text, "", "retry with r"], {width, height})
    end
  end

  defp disconnected?(message) do
    text = message_text(message)
    String.contains?(text, "daemon_unavailable") or String.contains?(text, "daemon_died")
  end

  # Wire failures may carry non-binary reasons (a raised exception folded
  # by the runtime's async envelope); every render path normalizes first.
  defp message_text(message) when is_binary(message), do: message
  defp message_text(message), do: inspect(message)

  defp caps_readiness(state) do
    case {Map.get(state.cache, :status), Map.get(state.cache, :plan)} do
      {{:ok, _}, {:ok, _}} ->
        if state.caps_env, do: :ready, else: {:loading, [:status, :plan]}

      {{:error, message}, _} ->
        {:error, message}

      {_, {:error, message}} ->
        {:error, message}

      {status, plan} ->
        missing =
          for {wire, value} <- [status: status, plan: plan],
              value in [nil, :loading] do
            wire
          end

        {:loading, missing}
    end
  end

  defp home_frame(state, {width, height}) do
    Helpers.frame(home_lines(state), {width, height})
  end

  defp home_lines(state) do
    hint_line =
      if state.update_hint do
        [UpdateHint.text(state.update_hint)]
      else
        []
      end

    keys = "keys: 1-7 tabs · ←→ switch · r refresh · ? help · a apply" <> u_hint(state) <> " · q quit"

    [
      "engine: " <> engine_line(state),
      "journal: " <> journal_line(state),
      "plan: " <> plan_line(state),
      "diff: " <> diff_line(state),
      "capabilities: " <> caps_line(state),
      "daemon: " <> daemon_line(state)
    ] ++
      hint_line ++
      [
        "",
        keys,
        "verbs: standalone entry points keep working (workstation apply --headless, …)"
      ]
  end

  defp u_hint(%{update_hint: hint}) when hint != nil, do: " · u update"
  defp u_hint(_state), do: ""

  # Per-wire lines fold each cached load state into one honest phrase —
  # loading, the data, or the failure verbatim.
  defp engine_line(%{cache: %{status: {:ok, status}}}) do
    engine = status["engine"] || %{}

    "#{Map.get(engine, "name", "?")} #{Map.get(engine, "version", "?")} " <>
      "(#{Map.get(engine, "mode", "?")}) · platform #{Map.get(status, "platform", "?")} · " <>
      "#{length(status["packages"] || [])} packages"
  end

  defp engine_line(%{cache: %{status: {:error, message}}}),
    do: "unavailable — #{message_text(message)}"
  defp engine_line(_state), do: "loading…"

  defp journal_line(%{cache: %{status: {:ok, status}}}) do
    case status["journal"] do
      journal when is_map(journal) ->
        "generation #{journal["generation"]} (applied#{applied_at(journal)})"

      _other ->
        "none — nothing applied yet"
    end
  end

  defp journal_line(_state), do: "…"

  defp applied_at(%{"applied_at" => at}) when is_binary(at), do: " #{at}"
  defp applied_at(_journal), do: ""

  defp plan_line(%{cache: %{plan: {:ok, plan}}}) do
    body = plan["plan"] || %{}

    "generation #{Map.get(plan, "generation", "?")} · " <>
      "#{length(body["entries"] || [])} entries · #{length(body["removals"] || [])} removals"
  end

  defp plan_line(%{cache: %{plan: {:error, message}}}),
    do: "unavailable — #{message_text(message)}"
  defp plan_line(_state), do: "loading…"

  defp diff_line(%{cache: %{diff: {:ok, diff}}}) do
    records = diff["backend_diff"] || []

    if records == [] do
      "no differences — the destination matches the desired state"
    else
      "#{length(records)} pending change(s) — 5 diff"
    end
  end

  defp diff_line(%{cache: %{diff: {:error, message}}}),
    do: "unavailable — #{message_text(message)}"
  defp diff_line(_state), do: "loading…"

  defp caps_line(%{caps_env: %{} = envelope}) do
    "#{length(envelope["domains"] || [])} domains · " <>
      "#{Capabilities.total_files(envelope)} files · " <>
      "#{Capabilities.total_planned(envelope)} would change · " <>
      "applied #{envelope["applied_generation"] || "none"} — 2 capabilities"
  end

  defp caps_line(%{cache: %{status: {:error, message}}}),
    do: "unavailable — #{message_text(message)}"
  defp caps_line(_state), do: "loading…"

  defp daemon_line(%{cache: %{status: {:ok, _wire}}}) do
    "reachable (status answered — reads and ops go through it)"
  end

  defp daemon_line(%{cache: %{status: {:error, message}}}) do
    text = message_text(message)

    if disconnected?(text) do
      "unreachable — start it with `workstation daemon` · retry r"
    else
      "error — #{text} · retry r"
    end
  end

  defp daemon_line(_state), do: "probing…"

  defp daemon_frame(state, {width, height}) do
    status = Map.get(state.cache, :status)

    lines =
      case status do
        {:ok, wire} ->
          engine = wire["engine"] || %{}
          journal = wire["journal"]

          [
            "daemon health (live probe: status.run)",
            "",
            "state       : reachable",
            "engine      : #{Map.get(engine, "name", "?")} #{Map.get(engine, "version", "?")} (#{Map.get(engine, "mode", "?")})",
            "destination : #{Map.get(wire, "destination", "?")}",
            "platform    : #{Map.get(wire, "platform", "?")}",
            "packages    : #{length(wire["packages"] || [])} in the collected desired state",
            "graph order : #{length(wire["graph_order"] || [])} resolved",
            "journal     : " <>
              if(is_map(journal),
                do: "generation #{journal["generation"]}",
                else: "none"
              ),
            "",
            "the daemon is the only mutation engine; the shell's reads and ops",
            "are protocol calls, never in-process fallbacks.",
            "",
            "r re-probe"
          ]

        {:error, message} ->
          text = message_text(message)

          [
            "daemon health (live probe: status.run)",
            "",
            "state : unreachable",
            text,
            "",
            "start it with `workstation daemon` — the client spawns it detached",
            "from the same release when absent; retry with r"
          ]

        _loading ->
          ["daemon health (live probe: status.run)", "", "probing…", "", "r re-probe"]
      end

    Helpers.frame(lines, {width, height})
  end

  defp footer_frame(state, {width, height}) do
    # The capabilities tab keeps the arrows for drill-down, so its footer
    # names the drill grammar instead of the switch grammar.
    base =
      if state.tab == :capabilities do
        "1-7 tabs · ↑↓ move · enter/→ expand · ←/backspace collapse · r refresh · ? help · q quit"
      else
        "1-7 tabs · ←→ switch · r refresh · ? help · q quit"
      end

    line =
      if state.tab == :home do
        home_keys = "a apply" <> u_hint(state)
        [[{home_keys, accent_style(state)}, " · ", base]]
      else
        [base]
      end

    Helpers.frame(line, {width, height})
  end

  defp accent_style(state) do
    case accent_rgb(state) do
      {r, g, b} -> Style.new(fg: {:rgb, r, g, b}, attrs: [:bold])
      nil -> Style.new(attrs: [:bold])
    end
  end

  defp accent_rgb(state) do
    case Theme.to_term_ui_color(state.theme[:accent]) do
      {:rgb, r, g, b} -> {r, g, b}
      nil -> nil
    end
  end
end
