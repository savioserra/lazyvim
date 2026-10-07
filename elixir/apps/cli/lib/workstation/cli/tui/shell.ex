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
  alias Workstation.CLI.TUI.Shell.{Box, CapabilitiesBrowser, Help, TextView}

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
    :toast_ms,
    :now
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
      toast_ms: Keyword.get(opts, :toast_ms, 5_000),
      # Render clock: injected so ramp (staleness) renders are deterministic
      # under replay; production takes the boot time exactly once.
      now: Keyword.get(opts, :now, DateTime.utc_now())
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
  def update({:shell_check_done, verdict}, state),
    do: %{state | update_hint: UpdateHint.fold(verdict)}

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
    try do
      do_view(state)
    rescue
      e ->
        :persistent_term.put({:tui_probe, :view_crash}, {e, __STACKTRACE__})
        raise e
    end
  end

  def do_view(state) do
    {width, height} = state.dimensions

    heights =
      if state.op do
        # In op mode the embedded screen renders its own footer; the shell
        # keeps only the header and the tab strip (which shows where you
        # are: the op screen's pseudo-tab is highlighted).
        [3, 1, :fill]
      else
        [3, 1, :fill, 1]
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
    # Body rect of the op-mode layout ([3, 1, :fill] — 3-row brand
    # header + strip, no shell footer).
    # Layout.column answers a LIST of rects.
    [_header, _strip, body] =
      Layout.column(Layout.new(state.dimensions), [3, 1, max(height - 4, 1)])

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
    styles = theme_styles(state)

    Helpers.frame(
      [
        [{" workstation ", styles.accent}, {state.destination, Style.new()}],
        identity_row(state, styles),
        [{String.duplicate("═", width), styles.chrome}]
      ],
      {width, height}
    )
  end

  # Identity line: engine version + mode + journal generation/revision
  # from the cached status wire (loading degrades to a quiet phrase),
  # with the update indicator riding as a warn island when it shows.
  defp identity_row(state, styles) do
    base =
      case Map.get(state.cache, :status) do
        {:ok, wire} ->
          engine = wire["engine"] || %{}
          journal = wire["journal"] || %{}

          [
            {"v#{Map.get(engine, "version", "?")}", Style.new()},
            {" · ", styles.chrome},
            {"#{Map.get(engine, "mode", "?")} mode", Style.new()},
            {" · ", styles.chrome},
            {"gen #{Map.get(journal, "generation", "?")}", Style.new()},
            {" · ", styles.chrome},
            {"rev #{Map.get(journal, "revision", "?")}", Style.new()}
          ]

        _loading ->
          [{"reading engine state…", styles.inactive}]
      end

    case state.update_hint do
      nil -> base
      hint -> base ++ [{" · ", styles.chrome}, {UpdateHint.text(hint), styles.warn}]
    end
  end

  defp strip_frame(state, {width, height}) do
    entries =
      if state.op do
        Enum.map(@tabs, fn {id, label} -> {id, label, false} end) ++
          [{op_tab_id(state.op), op_tab_label(state.op), true}]
      else
        Enum.map(@tabs, fn {id, label} -> {id, label, false} end)
      end

    styles = theme_styles(state)

    # btop buttonbar islands on the strip row: `┘1 home└┘2 capabilities└…`.
    # The digit always rides the shortcut slot; the active tab label is
    # accent (bold), the rest read inactive. A chrome `─` filler carries
    # the bar to the terminal edge — islands left, border filler right;
    # the brief defines no right-side region content, so the filler IS
    # the right side and the strip reads as one bar at every width.
    islands =
      entries
      |> Enum.with_index()
      |> Enum.flat_map(fn {{id, label, _active}, index} ->
        label_style = if id == state.tab, do: styles.accent, else: styles.inactive

        [
          {"┘", styles.chrome},
          {"#{index + 1}", styles.shortcut},
          {label, label_style},
          {"└", styles.chrome}
        ]
      end)

    Helpers.frame([chrome_bar(islands, width, styles)], {width, height})
  end

  defp op_tab_id({:apply, _sub}), do: :apply_op
  defp op_tab_id({:update, _sub}), do: :update_op
  defp op_tab_label({:apply, _sub}), do: "apply"
  defp op_tab_label({:update, _sub}), do: "update"

  # One full-width chrome bar: keycap islands, then `─` to the terminal
  # edge (the shared bar grammar of the tab strip and the global footer).
  defp chrome_bar(islands, width, styles) do
    used = Enum.sum(Enum.map(islands, fn {text, _style} -> Helpers.text_width(text) end))

    islands ++ [{String.duplicate("─", max(width - used, 0)), styles.chrome}]
  end

  defp body_frame(%{op: {kind, sub}}, _dims), do: op_module(kind).view(sub)

  defp body_frame(%{op: nil, tab: :home} = state, dims), do: home_frame(state, dims)
  defp body_frame(%{op: nil, tab: :daemon} = state, dims), do: daemon_frame(state, dims)
  defp body_frame(%{op: nil, tab: :help} = state, dims) do
    # The key reference is longer than most panes: render it as a boxed
    # scrollable text view (↑↓ / pgup/pgdn + the border block scrollbar)
    # so nothing is clipped.
    styles = theme_styles(state)
    view = Map.get(state.text_views, :help) || TextView.init(Enum.join(Help.lines(), "\n"))

    TextView.bordered_view(view, dims, %{
      title: [{"7", styles.shortcut}, {" help", styles.accent}],
      border: styles.chrome,
      shortcut: styles.shortcut,
      chrome: styles.chrome,
      thumb: styles.shortcut
    })
  end

  defp body_frame(%{op: nil, tab: tab, text_views: views} = state, dims)
       when tab in [:status, :plan, :diff] do
    case Map.get(state.cache, tab) do
      {:ok, _wire} ->
        # btop anatomy: the box title island carries the tab digit + name,
        # the top-border right island the sync/would-change badge, the
        # bottom border the action bar (scroll, refresh, position counter)
        # and overflow rides the right-border block scrollbar.
        styles = theme_styles(state)

        TextView.bordered_view(Map.get(views, tab) || TextView.init(""), dims, %{
          title: [{tab_digit(tab), styles.shortcut}, {" #{tab}", styles.accent}],
          right: read_badge(state, tab, styles),
          border: styles.chrome,
          shortcut: styles.shortcut,
          chrome: styles.chrome,
          thumb: styles.shortcut
        })

      {:error, message} ->
        error_frame(state, tab, "#{tab}: #{message_text(message)}", dims)

      _loading ->
        placeholder(state, tab, "loading #{tab} — the daemon is collecting state", dims)
    end
  end


  defp body_frame(%{op: nil, tab: :capabilities} = state, dims) do
    styles = theme_styles(state)
    title = [{"2", styles.shortcut}, {" capabilities ", styles.accent}]

    case caps_readiness(state) do
      :ready ->
        CapabilitiesBrowser.view(state.caps, dims, Map.put(styles, :title, title))

      {:loading, missing} ->
        placeholder(state, :capabilities, "loading #{Enum.join(missing, ", ")} — the daemon is collecting state", dims)

      {:error, message} ->
        error_frame(state, :capabilities, "capabilities: #{message_text(message)}", dims)

    end
  end
  # Tab digits mirror the strip order (1-based over @tabs) so the box
  # titles advertise the strip shortcut.
  defp tab_digit(tab) do
    index = Enum.find_index(@tabs, fn {id, _label} -> id == tab end) || 0
    "#{index + 1}"
  end

  # Top-border badge per read tab: status carries the journal generation
  # plus the sync verdict; plan and diff reuse the home would-change and
  # pending badges.
  defp read_badge(state, :status, styles) do
    case status_journal(state) do
      nil ->
        []

      journal ->
        gen = [{"gen #{journal["generation"]}", styles.chrome}]

        verdict =
          case Map.get(state.cache, :diff) do
            {:ok, diff} ->
              pending = length(diff["backend_diff"] || [])

              if pending > 0 do
                [{" · #{pending} pending", styles.warn}]
              else
                [{" · in-sync", styles.ok}]
              end

            _other ->
              []
          end

        gen ++ verdict
    end
  end

  defp read_badge(state, :plan, styles), do: pending_badge(state, :plan, styles)
  defp read_badge(state, :diff, styles), do: pending_badge(state, :diff, styles)

  defp status_journal(%{cache: %{status: {:ok, status}}}), do: status["journal"]
  defp status_journal(_state), do: nil

  # Loading and failure states keep the box anatomy: the tab island
  # titles the box, the body carries the honest state verbatim.
  defp placeholder(state, tab, line, {width, height}) do
    styles = theme_styles(state)

    Box.frame(
      [
        [{" " <> line, styles.inactive}],
        [],
        [{" retry with r", styles.inactive}]
      ],
      {width, height},
      border_style: styles.chrome,
      title: [{tab_digit(tab), styles.shortcut}, {" #{tab}", styles.accent}]
    )
  end

  # Read failures split into the transport shape (daemon unreachable —
  # the recovery hint names the start command) and every other failure
  # (the verbatim message; r retries either way). Errors read err; the
  # retry action rides the border as a button.
  defp error_frame(state, tab, message, {width, height}) do
    styles = theme_styles(state)

    Box.frame(error_rows(message, styles), {width, height},
      border_style: styles.chrome,
      title: [{tab_digit(tab), styles.shortcut}, {" #{tab}", styles.err}],
      buttons: [[{"r", styles.shortcut}, {" retry", styles.chrome}]]
    )
  end

  defp error_rows(message, styles) do
    if disconnected?(message) do
      [
        [{" daemon unreachable", styles.err}],
        [{" " <> message, styles.err}],
        [],
        [{" start it with `workstation daemon` — retry with r", styles.err}]
      ]
    else
      [
        [{" read failed", styles.err}],
        [{" " <> message, styles.err}],
        [],
        [{" retry with r", styles.err}]
      ]
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

  # Below this width the 2x2 mosaic halves squeeze below readability and
  # the home falls back to the vertical stack (brief priority: engine >
  # journal > domains > plan/diff).
  @home_mosaic_min_width 110

  # Stack boxes in priority order; each bounded fill claims its minimum
  # height, shares the surplus as fill, and — when the body cannot honor
  # every minimum — the layout solver scales the minimums proportionally
  # instead of clipping a box away. Content beyond a shrunken box elides
  # inside its (still closed) borders.
  @stack_box_heights [3, 3, 4, 3, 3]

  defp home_frame(state, dims) do
    if home_mosaic?(dims), do: mosaic_frame(state, dims), else: stack_frame(state, dims)
  end

  defp home_mosaic?({width, _height}), do: width >= @home_mosaic_min_width

  defp mosaic_frame(state, dims) do
    {width, height} = dims
    styles = theme_styles(state)

    [row1, row2, row3] =
      Layout.column(Layout.new({width, height}), [
        Layout.fill(),
        Layout.fill(),
        # The capabilities band carries rollup + meters + the update hint
        # row — three body rows minimum, or the hint clips.
        Layout.fixed(5)
      ])

    [left1, right1] = Layout.row(row1, [Layout.percentage(50), Layout.fill()])
    [left2, right2] = Layout.row(row2, [Layout.percentage(50), Layout.fill()])

    Helpers.frame([], {width, height})
    |> Helpers.compose(left1, &engine_box(state, styles, &1))
    |> Helpers.compose(right1, &journal_box(state, styles, &1))
    |> Helpers.compose(left2, &plan_box(state, styles, &1))
    |> Helpers.compose(right2, &diff_box(state, styles, &1))
    |> Helpers.compose(row3, &caps_box(state, styles, &1))
  end

  # Narrow home: the five dashboard boxes stack full width in the brief's
  # priority order (engine, journal, domains, then the plan/diff pair).
  defp stack_frame(state, {width, height}) do
    styles = theme_styles(state)

    boxes = [
      &engine_box/3,
      &journal_box/3,
      &caps_box/3,
      &plan_box/3,
      &diff_box/3
    ]

    tracks = Enum.map(@stack_box_heights, &Layout.bounded(Layout.fill(), min: &1))

    boxes
    |> Enum.zip(Layout.column(Layout.new({width, height}), tracks))
    |> Enum.reduce(Helpers.frame([], {width, height}), fn {box, rect}, frame ->
      Helpers.compose(frame, rect, &box.(state, styles, &1))
    end)
  end

  ## home mosaic (btop dashboard: adjacent rounded boxes, island titles,
  ## border buttons/counters, block meters — Shell.Box anatomy)

  defp engine_box(state, styles, dims) do
    Box.frame(engine_rows(state, styles), dims,
      border_style: styles.chrome,
      title: [{"1", styles.shortcut}, {" engine ", styles.accent}],
      right: daemon_badge(state, styles)
    )
  end

  defp journal_box(state, styles, dims) do
    Box.frame(journal_rows(state, styles), dims,
      border_style: styles.chrome,
      title: [{" journal ", styles.accent}]
    )
  end

  defp plan_box(state, styles, dims) do
    Box.frame(plan_rows(state, styles), dims,
      border_style: styles.chrome,
      title: [{"4", styles.shortcut}, {" plan ", styles.accent}],
      right: pending_badge(state, :plan, styles)
    )
  end

  defp diff_box(state, styles, dims) do
    Box.frame(diff_rows(state, styles), dims,
      border_style: styles.chrome,
      title: [{"5", styles.shortcut}, {" diff ", styles.accent}],
      right: pending_badge(state, :diff, styles)
    )
  end

  # The actions box: per-domain block meters over the collected desired
  # state; the bottom border doubles as the home buttonbar (apply/update
  # appear exactly when their key works)."""
  defp caps_box(state, styles, dims) do
    Box.frame(caps_rows(state, styles), dims,
      border_style: styles.chrome,
      title: [{"2", styles.shortcut}, {" capabilities ", styles.accent}],
      buttons: [[{"a", styles.shortcut}, {" apply", styles.chrome}]] ++
                 u_button(state, styles) ++
                 [[{"r", styles.shortcut}, {" refresh", styles.chrome}]]
    )
  end

  # `u update` rides the buttonbar only while the update is available —
  # the same honesty rule as the old keys line (a key that does nothing
  # must not be advertised).
  defp u_button(%{update_hint: hint}, styles) when hint != nil do
    [[{"u", styles.shortcut}, {" update", styles.chrome}]]
  end

  defp u_button(_state, _styles), do: []

  # `label      value` body row: the label reads inactive (dimmed
  # chrome), the value carries its own role span (or plain text). The
  # pad guarantees a separator space after the longest label.
  defp label_row(label, value, styles) do
    pad = max(12, String.length(label) + 3)

    [{" " <> String.pad_trailing(label <> ":", pad), styles.inactive}, as_value(value)]
  end

  defp as_value(value) when is_binary(value), do: {value, Style.new()}
  defp as_value({text, _style} = span) when is_binary(text), do: span

  # Liveness badge on the engine box's top border: one state glyph, one
  # role color (accent reachable, err unreachable, inactive probing).
  defp daemon_badge(state, styles) do
    case Map.get(state.cache, :status) do
      {:ok, _wire} -> [{"● reachable", styles.accent}]
      {:error, _message} -> [{"● unreachable", styles.err}]
      _loading -> [{"● probing", styles.inactive}]
    end
  end

  defp engine_rows(%{cache: %{status: {:ok, wire}}}, styles) do
    engine = wire["engine"] || %{}

    [
      label_row(
        "engine",
        "#{Map.get(engine, "name", "?")} #{Map.get(engine, "version", "?")} (#{Map.get(engine, "mode", "?")})",
        styles
      ),
      label_row("platform", Map.get(wire, "platform", "?"), styles),
      label_row("packages", "#{length(wire["packages"] || [])} in the collected desired state", styles)
    ]
  end

  defp engine_rows(%{cache: %{status: {:error, message}}}, styles) do
    [label_row("engine", {message_text(message), styles.err}, styles)]
  end

  defp engine_rows(_state, styles), do: [label_row("engine", "loading…", styles)]

  # Journal box: generation, applied stamp and the age meter. The meter
  # rides the ramp trio by applied-at age: fresh ok, aging warn, stale err.
  defp journal_rows(%{cache: %{status: {:ok, status}}} = state, styles) do
    case status["journal"] do
      journal when is_map(journal) ->
        style = ramp_style(state, journal["applied_at"])

        [
          label_row("generation", to_string(journal["generation"]), styles),
          label_row("applied", {applied_at(journal), style}, styles),
          [{" " <> age_bar(state, journal["applied_at"]), style}]
        ]

      _other ->
        [label_row("journal", "none — nothing applied yet", styles)]
    end
  end

  defp journal_rows(_state, styles), do: [label_row("journal", "loading…", styles)]

  # Applied-at age as a block meter: 0 cells (fresh) to full (stale).
  # Ramp thresholds: fresh <24h ok · aging <7d warn · stale ≥7d err; an
  # absent or unparseable stamp renders plain.
  @age_bar_cells 10
  @fresh_after_seconds 86_400
  @aging_after_seconds 604_800

  defp age_bar(state, applied_at) do
    filled =
      case stamp_age_seconds(state, applied_at) do
        nil -> 0
        age -> age |> Kernel.*(@age_bar_cells) |> div(@aging_after_seconds) |> max(0) |> min(@age_bar_cells)
      end

    String.duplicate("▇", filled) <> String.duplicate("▁", @age_bar_cells - filled)
  end

  defp ramp_style(state, applied_at) do
    styles = theme_styles(state)

    case stamp_age_seconds(state, applied_at) do
      nil -> Style.new()
      age when age < @fresh_after_seconds -> styles.ramp_start
      age when age < @aging_after_seconds -> styles.ramp_mid
      _age -> styles.ramp_end
    end
  end

  defp stamp_age_seconds(state, applied_at) when is_binary(applied_at) do
    case DateTime.from_iso8601(applied_at) do
      {:ok, stamp, _offset} -> max(DateTime.diff(state.now, stamp, :second), 0)
      {:error, _reason} -> nil
    end
  end

  defp stamp_age_seconds(_state, _applied_at), do: nil

  # Per-wire rows fold each cached load state into one honest phrase —
  # loading, the data, or the failure verbatim.
  defp applied_at(%{"applied_at" => at}) when is_binary(at), do: " #{at}"
  defp applied_at(_journal), do: ""

  defp plan_rows(%{cache: %{plan: {:ok, plan}}}, styles) do
    body = plan["plan"] || %{}
    entries = length(body["entries"] || [])
    removals = length(body["removals"] || [])
    warn = if entries > 0 or removals > 0, do: styles.warn, else: Style.new()

    [
      label_row("generation", Map.get(plan, "generation", "?"), styles),
      label_row("entries", {"#{entries}", warn}, styles),
      label_row("removals", {"#{removals}", warn}, styles)
    ]
  end

  defp plan_rows(%{cache: %{plan: {:error, message}}}, styles) do
    [label_row("plan", {message_text(message), styles.err}, styles)]
  end

  defp plan_rows(_state, styles), do: [label_row("plan", "loading…", styles)]

  defp diff_rows(%{cache: %{diff: {:ok, diff}}}, styles) do
    records = diff["backend_diff"] || []
    count = length(records)
    style = if count > 0, do: styles.warn, else: styles.ok

    note =
      if records == [] do
        [{" no differences — the destination matches the desired state", styles.ok}]
      else
        []
      end

    [
      label_row("pending", {"#{count} pending change(s)", style}, styles),
      note
    ]
  end

  defp diff_rows(%{cache: %{diff: {:error, message}}}, styles) do
    [label_row("diff", {message_text(message), styles.err}, styles)]
  end

  defp diff_rows(_state, styles), do: [label_row("diff", "loading…", styles)]

  defp caps_rows(%{caps_env: %{} = envelope} = state, styles) do
    domains = envelope["domains"] || []
    max_files = domains |> Enum.map(&(&1["files"] || 0)) |> Enum.max(fn -> 0 end)

    [
      label_row(
        "rollup",
        "#{length(domains)} domains · #{Capabilities.total_files(envelope)} files · " <>
          "#{Capabilities.total_planned(envelope)} would change · " <>
          "applied #{envelope["applied_generation"] || "none"}",
        styles
      )
    ] ++
      Enum.map(domains, &domain_meter_row(&1, max_files, styles)) ++
      hint_rows(state, styles)
  end

  defp caps_rows(%{cache: %{status: {:error, message}}}, styles) do
    [label_row("capabilities", {message_text(message), styles.err}, styles)]
  end

  defp caps_rows(_state, styles), do: [label_row("capabilities", "loading…", styles)]

  # One block meter per domain: fill ∝ files relative to the largest
  # domain; a domain with pending would-change rows reads warn.
  @meter_cells 10

  defp domain_meter_row(domain, max_files, styles) do
    files = domain["files"] || 0
    planned = domain["planned"] || 0
    fill = if max_files > 0, do: div(files * @meter_cells, max_files), else: 0
    fill_style = if planned > 0, do: styles.warn, else: styles.accent

    [
      {" " <> String.pad_trailing("#{domain["name"]}", 12), styles.inactive},
      {String.duplicate("▇", fill) <> String.duplicate("▁", @meter_cells - fill), fill_style},
      {" #{files} files · ", Style.new()},
      {"#{planned} would change", if(planned > 0, do: styles.warn, else: styles.inactive)}
    ]
  end

  # The update hint rides the capabilities box body (and its border
  # button); no hint means no row.
  # A single body row (a list of spans) — the caller appends rows, so the
  # row itself carries one nesting level.
  defp hint_rows(%{update_hint: hint}, styles) when hint != nil do
    [[{" " <> UpdateHint.text(hint), styles.warn}]]
  end

  defp hint_rows(_state, _styles), do: []

  # Right-island would-change badges: saturated (warn) only when the
  # surface actually has pending work, quiet otherwise.
  defp pending_badge(state, :plan, styles) do
    case Map.get(state.cache, :plan) do
      {:ok, plan} ->
        body = plan["plan"] || %{}
        would = length(body["entries"] || []) + length(body["removals"] || [])
        if would > 0, do: [{"#{would} would change", styles.warn}], else: [{"clean", styles.ok}]

      _other ->
        []
    end
  end

  defp pending_badge(state, :diff, styles) do
    case Map.get(state.cache, :diff) do
      {:ok, diff} ->
        pending = length(diff["backend_diff"] || [])
        if pending > 0, do: [{"#{pending} pending", styles.warn}], else: [{"in-sync", styles.ok}]

      _other ->
        []
    end
  end

  ## daemon tab (two boxes: liveness + host)

  defp daemon_frame(state, dims) do
    {width, height} = dims
    styles = theme_styles(state)

    [left, right] = Layout.row(Layout.new({width, height}), [Layout.percentage(40), Layout.fill()])

    Helpers.frame([], {width, height})
    |> Helpers.compose(left, &liveness_box(state, styles, &1))
    |> Helpers.compose(right, &host_box(state, styles, &1))
  end

  # Liveness: one state row, one probe verb, the border button re-probes.
  defp liveness_box(state, styles, {width, height}) do
    Box.frame(liveness_rows(state, styles), {width, height},
      border_style: styles.chrome,
      title: [{"6", styles.shortcut}, {" daemon", styles.accent}],
      right: daemon_badge(state, styles),
      buttons: [[{"r", styles.shortcut}, {" re-probe", styles.chrome}]]
    )
  end

  # Host facts and protocol notes; daemon failures land here verbatim
  # with the recovery hint.
  defp host_box(state, styles, {width, height}) do
    Box.frame(host_rows(state, styles), {width, height},
      border_style: styles.chrome,
      title: [{"host", styles.accent}]
    )
  end

  defp liveness_rows(%{cache: %{status: {:ok, wire}}} = state, styles) do
    engine = wire["engine"] || %{}
    journal = wire["journal"]

    journal_row =
      case journal do
        j when is_map(j) ->
          label_row("journal", {"generation #{j["generation"]}", ramp_style(state, j["applied_at"])}, styles)

        _other ->
          label_row("journal", "none", styles)
      end

    [
      label_row("state", {"reachable", styles.accent}, styles),
      label_row(
        "engine",
        "#{Map.get(engine, "name", "?")} #{Map.get(engine, "version", "?")} (#{Map.get(engine, "mode", "?")})",
        styles
      ),
      journal_row,
      [{" the daemon is the only mutation engine", styles.inactive}],
      [{" reads and ops are protocol calls, never in-process fallbacks", styles.inactive}]
    ]
  end

  defp liveness_rows(%{cache: %{status: {:error, _message}}}, styles) do
    [label_row("state", {"unreachable", styles.err}, styles)]
  end

  defp liveness_rows(_state, styles), do: [label_row("state", "probing…", styles)]

  defp host_rows(%{cache: %{status: {:ok, wire}}}, styles) do
    [
      label_row("destination", Map.get(wire, "destination", "?"), styles),
      label_row("platform", Map.get(wire, "platform", "?"), styles),
      label_row("graph order", "#{length(wire["graph_order"] || [])} resolved", styles)
    ]
  end

  defp host_rows(%{cache: %{status: {:error, message}}} = _state, styles) do
    text = message_text(message)

    [
      [{" " <> text, styles.err}],
      [{" start it with `workstation daemon` — the client spawns it detached", styles.inactive}],
      [{" from the same release when absent; retry with r", styles.inactive}]
    ]
  end

  defp host_rows(_state, styles), do: [[{" probing…", styles.inactive}]]

  defp footer_frame(state, {width, height}) do
    # Global footer keeps the frame keys only (btop grammar: chrome bar,
    # glowing key caps). Tab-specific action hints live on their views'
    # borders; home's a/u stay documented in the home body.
    styles = theme_styles(state)

    line =
      [
        [{"1-7", styles.shortcut}, {" tabs", Style.new()}],
        [{"←→", styles.shortcut}, {" switch", Style.new()}],
        [{"r", styles.shortcut}, {" refresh", Style.new()}],
        [{"?", styles.shortcut}, {" help", Style.new()}],
        [{"q", styles.shortcut}, {" quit", Style.new()}]
      ]
      |> Enum.flat_map(fn button -> [{"┘", styles.chrome}] ++ button ++ [{"└", styles.chrome}] end)

    Helpers.frame([chrome_bar(line, width, styles)], {width, height})
  end

  # The resolved btop-grammar role styles for one render: every visual
  # claim routes through the theme envelope roles (never literals).
  defp theme_styles(state) do
    %{
      accent: role_style(state, :accent, fallback: Style.new(attrs: [:bold]), attrs: [:bold]),
      ok: role_style(state, :ok, fallback: :green),
      warn: role_style(state, :warn, fallback: :yellow),
      err: role_style(state, :err, fallback: :red),
      shortcut: role_style(state, :shortcut, fallback: Style.new(attrs: [:bold])),
      inactive: role_style(state, :inactive, fallback: :bright_black),
      chrome: role_style(state, :chrome, fallback: :bright_black),
      ramp_start: role_style(state, :ramp_start, fallback: :green),
      ramp_mid: role_style(state, :ramp_mid, fallback: :yellow),
      ramp_end: role_style(state, :ramp_end, fallback: :red),
      selected: selected_style(state),
      plain: Style.new()
    }
  end

  defp role_style(state, role, opts) do
    {fallback, opts} = Keyword.pop(opts, :fallback)

    case Theme.to_term_ui_color(state.theme[role]) do
      {:rgb, r, g, b} ->
        Style.new(Keyword.put(opts, :fg, {:rgb, r, g, b}))

      nil ->
        case fallback do
          %Style{} = style -> style
          color -> Style.new(Keyword.put(opts, :fg, color))
        end
    end
  end

  # Selection is a bg+fg pair (never color-alone); without the pair the
  # cursor falls back to reverse video.
  defp selected_style(state) do
    bg = Theme.to_term_ui_color(state.theme[:selected_bg])
    fg = Theme.to_term_ui_color(state.theme[:selected_fg])

    case {bg, fg} do
      {{:rgb, r, g, b}, {:rgb, r2, g2, b2}} ->
        Style.new(bg: {:rgb, r, g, b}, fg: {:rgb, r2, g2, b2}, attrs: [:bold])

      _missing ->
        Style.new(attrs: [:reverse])
    end
  end
end
