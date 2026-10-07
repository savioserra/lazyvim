defmodule Workstation.CLI.TUI.Shell do
  @moduledoc """
  The workstation TUI application shell — the one dashboard. One Elm root
  (the same `TermUI.Elm` contract as the apply/update screens) owning the
  global chrome: a keycap toggle strip on the top row, the six-box
  dashboard as the entire app, and a footer with the global keys
  (btop-ia-spec §2). The mosaic IS the app — there are no tabs:

    * digits 1-6 toggle the boxes (`Shell.Dashboard.toggle_box`:
      flip membership, min-size gate, re-tile; a hidden box's strip
      island renders dimmed as `[n] label`);
    * p/P cycle the presets (full mosaic / audit / minimal, wrap-around);
    * `?` toggles the help reference (the paged overlay lands with the
      overlay lane);
    * `a` / `u` open the apply/update screens INSIDE the app: the shell
      embeds `Workstation.CLI.TUI.Apply` / `.Update` over the body,
      reserving only `q` (leave the screen — a running op keeps running
      daemon-side, the detach semantics of the standalone screen) and the
      apply screen's `[u]` handoff, which swaps to the update screen.

  All reads go through the client (one `DaemonClient.call` per wire, the
  same ops the verbs send); the daemon is the only mutation engine — the
  shell never mutates anything itself, and the embedded screens speak the
  identical executor contract as standalone. The `:load`, `:executor`,
  `:update_executor` and `:check` seams are injected funs, so tests replay
  fixed wire/event streams with no daemon involved (deterministic replay).

  Data states are explicit per box: loading (probe in flight), data,
  error, and the daemon-disconnected shape (transport failure wording
  surfaced with the recovery hint). Keys are documented in the help pane.
  """

  use TermUI.Elm

  alias TermUI.{Command, Event, Layout, Style}
  alias TermUI.Widget.Helpers

  alias Workstation.CLI.{Capabilities, Render}
  alias Workstation.CLI.DaemonClient
  alias Workstation.CLI.TUI.{Apply, Executor, Theme, Update, UpdateHint}
  alias Workstation.CLI.TUI.Shell.{Box, CapabilitiesBrowser, Dashboard, Help, TextView}

  @read_timeout_ms 120_000

  # The dashboard's wires: every box subscribes to the same reads the old
  # tabs did — the placement changed, the data seams did not (§2.5).
  @wires [:status, :plan, :diff]

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

  # Mouse coordinates are 0-based cells; the strip is the first row in
  # both layouts (do_view heights [1, ...]), so clicks are addressed at
  # 0-based y 0.
  @strip_row_y 0

  @type load_state :: nil | :loading | {:ok, map()} | {:error, String.t()}
  @type op_screen :: {:apply, Apply.t()} | {:update, Update.t()}

  defstruct [
    :destination,
    :theme,
    :dimensions,
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
    :now,
    # The six-box dashboard state: visible set + preset tracking.
    dashboard: Dashboard.new(),
    # The toggle gate's inline footer error (btop's SizeError toast);
    # lives exactly one unhandled keypress.
    flash: nil,
    # The help reference pane (? toggles; the paged overlay lands with
    # the overlay lane).
    help: false
  ]

  @type t :: %__MODULE__{
          destination: String.t(),
          theme: Theme.colors(),
          dimensions: {pos_integer(), pos_integer()},
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
          toast_ms: pos_integer(),
          dashboard: Dashboard.t(),
          flash: String.t() | nil,
          help: boolean()
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

    # Boot effects: the dashboard's three reads and the passive
    # availability probe — all asynchronous; the first frame paints
    # immediately in the loading state.
    {state, wire_commands} = load_commands(state, @wires, false)
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

  # Mouse: a left click on a strip island is that island's keypress —
  # a box digit toggle or the p/P preset cycle (the same update path —
  # one spelling for strip addressing); the wheel reuses the pane scroll
  # keys; everything else is inert. Coordinates are 0-based cells
  # (term_ui contract); the strip is 0-based row 0 — the first row of
  # both layouts.
  def event_to_msg(%Event.Mouse{action: :press, button: :left, y: @strip_row_y, x: x}, state) do
    case strip_key_at(state, x) do
      nil -> :ignore
      key -> {:msg, {:text, key}}
    end
  end

  def event_to_msg(%Event.Mouse{action: :scroll_up}, _state), do: {:msg, {:key, :up}}
  def event_to_msg(%Event.Mouse{action: :scroll_down}, _state), do: {:msg, {:key, :down}}

  # A left click inside a zoomable box toggles its deep view (§2.5:
  # click inside a zoomable box = zoom); the point is addressed in body
  # coordinates (the strip is row 0, the footer rides the last row).
  def event_to_msg(%Event.Mouse{action: :press, button: :left, x: x, y: y} = event, %{op: nil} = state)
      when y >= 1 do
    case box_at(state, x, y - 1) do
      box when box in [:capabilities, :plan, :diff] -> {:msg, {:box_click, box}}
      _other -> {:msg, event}
    end
  end

  def event_to_msg(%Event.Mouse{}, _state), do: :ignore

  def event_to_msg(_event, _state), do: :ignore

  @impl TermUI.Elm
  ## -- op mode: the embedded screen owns the keyboard --------------------

  # `q` leaves the screen (the standalone screen's quit semantics): a
  # running op keeps running daemon-side — the daemon owns the lock and
  # the journal records the outcome; the shell returns to the dashboard
  # and re-reads. op is a {kind, sub} tuple; the nil case falls to the
  # quit clause — a bare `op` pattern would also bind nil and make q
  # unquit-able.
  def update({:text, "q"}, %{op: op} = state) when not is_nil(op) do
    close_op(state)
  end

  # q on the dashboard quits the app (the footer's documented quit key).
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

  # Resize re-tiles the dashboard from the visible set and clears preset
  # tracking (§1.2 — a box resize breaks the preset bond exactly like a
  # manual toggle). No view routing: the boxes re-clip at render time.
  def update({:resize, width, height}, %{op: nil} = state) do
    %{
      state
      | dimensions: {width, height},
        dashboard: Dashboard.clear_tracking(state.dashboard),
        flash: nil
    }
  end

  def update(message, %{op: {kind, sub}} = state) do
    {sub, commands} = forward(op_module(kind), message, sub)
    {%{state | op: {kind, sub}}, commands}
  end

  ## -- dashboard mode -----------------------------------------------------

  # Digits 1-6 toggle dashboard boxes (Config::toggle_box semantics:
  # flip membership, min-size gate, re-tile); 0 and 7+ are inert (btop
  # refuses out-of-range digits the same way — they fall through to the
  # catch-all). A min-size refusal surfaces as the footer's inline flash.
  def update({:text, digit}, %{op: nil} = state) when digit in ~w(1 2 3 4 5 6) do
    box = Dashboard.box_for_key(digit)

    case Dashboard.toggle_box(state.dashboard, box, elem(state.dimensions, 0)) do
      {:ok, dashboard} ->
        %{state | dashboard: dashboard, flash: nil}

      {:error, min} ->
        %{state | flash: "#{box} needs >= #{min} columns"}
    end
  end

  # p/P cycle the presets (next/previous, wrap-around; §2.2).
  def update({:text, "p"}, %{op: nil} = state),
    do: %{state | dashboard: Dashboard.cycle(state.dashboard, :next), flash: nil}

  def update({:text, "P"}, %{op: nil} = state),
    do: %{state | dashboard: Dashboard.cycle(state.dashboard, :prev), flash: nil}

  # ? toggles the help reference (the paged overlay lands with the
  # overlay lane; §2.4 keeps the symmetric open/close key).
  def update({:text, "?"}, %{op: nil} = state), do: %{state | help: not state.help, flash: nil}

  # r refreshes the dashboard's reads — force reload even when cached.
  def update({:text, "r"}, %{op: nil} = state) do
    {state, commands} = load_commands(state, @wires, true)
    {%{state | flash: nil}, commands}
  end

  # a applies the current plan — the plan the shell already loaded; the
  # embedded screen applies exactly what was rendered.
  def update({:text, "a"}, %{op: nil, cache: %{plan: {:ok, plan}}} = state) do
    open_apply(plan, state)
  end

  # u runs the update flow when the availability probe found one.
  def update({:text, "u"}, %{op: nil, update_hint: hint} = state) when hint != nil do
    open_update(state)
  end

  ## -- in-box deep views (§1.6: drill/zoom never leave the dashboard) -----

  # Enter = the btop proc-detail key: expand the first visible zoomable
  # box in place (capabilities tree drill, plan/diff read zoom); Enter
  # again restores the tiler (btop_input.cpp:462-484 — Enter toggles
  # show_detailed).
  def update({:key, :enter}, %{op: nil, help: false} = state) do
    case Dashboard.expansion(state.dashboard) do
      nil ->
        box = Enum.find(~w(capabilities plan diff)a, &Dashboard.visible?(state.dashboard, &1))

        if box do
          {:ok, dashboard} = Dashboard.expand(state.dashboard, box)
          %{state | dashboard: dashboard, flash: nil}
        else
          state
        end

      _expanded ->
        %{state | dashboard: Dashboard.contract(state.dashboard), flash: nil}
    end
  end

  # Esc closes overlays outside-in: the help reference first, then the
  # box deep view (§2.4 — Esc-family keys are symmetric open/close).
  def update({:key, :escape}, %{op: nil, help: true} = state),
    do: %{state | help: false, flash: nil}

  def update({:key, :escape}, %{op: nil} = state) do
    if Dashboard.expansion(state.dashboard) != nil do
      %{state | dashboard: Dashboard.contract(state.dashboard), flash: nil}
    else
      state
    end
  end

  # A click inside a zoomable box toggles ITS deep view (§2.5: click
  # inside a zoomable box = zoom, the proc-detail analog); clicks do not
  # steal the deep view from the box that owns it.
  def update({:box_click, box}, %{op: nil, dashboard: dash} = state) do
    case Dashboard.expansion(dash) do
      ^box ->
        %{state | dashboard: Dashboard.contract(dash), flash: nil}

      nil ->
        {:ok, dashboard} = Dashboard.expand(dash, box)
        %{state | dashboard: dashboard, flash: nil}

      _other ->
        state
    end
  end

  # Arrows and scroll keys are the boxes' in-pane navigation: a zoomed
  # read scrolls its pane, everything else drives the capabilities
  # browser's cursor while box 2 is on the dashboard (the migration map:
  # arrows stopped being tab switchers, they live inside box 2). The
  # node drill is right/left (Enter is the box drill's toggle).
  @nav_keys [:up, :down, :left, :right, :page_up, :page_down, :home, :end, :backspace]

  def update({:key, key}, %{op: nil, help: false} = state) when key in @nav_keys do
    case scroll_target(state) do
      {:zoom, id} ->
        zoom_scroll(state, id, key)

      {:browser, _caps} ->
        %{state | caps: CapabilitiesBrowser.update({:key, key}, state.caps), flash: nil}

      nil ->
        if state.flash != nil, do: update({:key, key}, %{state | flash: nil}), else: state
    end
  end

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

  # Any unhandled key clears the footer flash: the inline error's
  # lifetime is exactly one keypress — the layout did not change under
  # it. Re-dispatch on the cleared state; every real clause sits above.
  def update(message, %{op: nil, flash: flash} = state) when flash != nil,
    do: update(message, %{state | flash: nil})

  # Scroll keys ride the help reference while it is open; every other
  # message is ignored (the boxes are static summaries until the overlay
  # lane adds their scrollable deep views).
  def update(message, %{op: nil, help: true, text_views: views} = state) do
    view = Map.get(views, :help) || TextView.init(Enum.join(Help.lines(), "\n"))
    %{state | text_views: Map.put(views, :help, TextView.update(message, view))}
  end

  def update(_message, state), do: state

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
        # keeps only the tab strip (which shows where you are: the op
        # screen's pseudo-tab is highlighted).
        [1, :fill]
      else
        [1, :fill, 1]
      end

    [strip, body | rest] = Layout.column(Layout.new({width, height}), heights)
    footer = List.first(rest)

    frame = Helpers.frame([], {width, height})

    frame
    |> Helpers.compose(strip, &strip_frame(state, &1))
    |> Helpers.compose(body, &body_frame(state, &1))
    |> compose_footer(footer, state)
  end

  # op-nil first: a bare %{op: _op} pattern would bind nil and swallow
  # the normal footer.
  defp compose_footer(frame, footer, %{op: nil} = state),
    do: Helpers.compose(frame, footer, &footer_frame(state, &1))

  defp compose_footer(frame, _footer, %{op: _op}), do: frame

  ## data loading

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

  # Derived views refresh as their wires land: the grouped capabilities
  # envelope (status+plan) that boxes 2-6 fold into their rows.
  defp refresh_derived(state, command, {:ok, _wire}) when command in [:status, :plan, :diff] do
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

  # What the scroll/nav keys address right now: a zoomed read's pane
  # (overlay panes are scrollable while focused, §2.5) or the
  # capabilities browser's cursor when box 2 is on the dashboard.
  defp scroll_target(%{dashboard: dash} = state) do
    case Dashboard.expansion(dash) do
      expansion when expansion in [:plan, :diff] ->
        {:zoom, :"#{expansion}_zoom"}

      _expansion ->
        if Dashboard.visible?(dash, :capabilities), do: {:browser, state.caps}, else: nil
    end
  end

  defp zoom_scroll(%{text_views: views} = state, id, key) do
    view = Map.get(views, id) || zoom_text_view(state, id)
    %{state | text_views: Map.put(views, id, TextView.update({:key, key}, view))}
  end

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

  # `a` embeds the apply screen: the plan the dashboard rendered is the
  # plan the screen applies (help pane closed — the op covers the pane);
  # `q` leaves without applying, `u` hands off to the update screen.
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

    {%{state | op: {:apply, sub}, help: false}, commands}
  end

  # `u` embeds the update screen; same body ownership contract as apply.
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

    {%{state | op: {:update, sub}, help: false}, commands}
  end

  # Leaving an op screen returns to the dashboard and re-reads: an apply
  # may have changed the world (or the daemon may still hold the lock —
  # the reads report that honestly).
  defp close_op(state) do
    state = %{state | op: nil}
    {state, commands} = load_commands(state, @wires, true)
    {state, commands}
  end

  defp body_dims(%{dimensions: {_width, height}} = state) do
    # Body rect of the op-mode layout ([1, :fill] — the strip only, no
    # shell footer). Layout.column answers a LIST of rects.
    [_strip, body] =
      Layout.column(Layout.new(state.dimensions), [1, max(height - 1, 1)])

    {elem(body, 2), elem(body, 3)}
  end

  ## rendering

  defp strip_frame(state, {width, height}) do
    styles = theme_styles(state)

    # btop buttonbar islands on the strip row. Visible boxes glow: the
    # superscript keycap rides the shortcut role (bold — btop's glowing
    # cap), the label the accent role (bold). Hidden boxes render dimmed
    # bracket islands `[4] plan` in the inactive role — the shortcut they
    # advertise is still live (digits toggle), the glow is what signals
    # membership. The p/P preset islands close the bar (§2.4); a chrome
    # `─` filler carries it to the terminal edge.
    islands =
      strip_islands(state, styles)
      |> Enum.map(fn {spans, _key} ->
        [{"┘", styles.chrome}] ++ spans ++ [{"└", styles.chrome}]
      end)

    Helpers.frame([chrome_bar(islands, nil, width, styles)], {width, height})
  end

  # Toggle-strip islands (§2.4): one per dashboard box — glowing when
  # visible, dimmed bracket-form when hidden — plus the p/P preset
  # islands. Shared by the strip renderer and the mouse router so click
  # = keypress has exactly one spelling.
  defp strip_islands(state, styles) do
    for island <- Dashboard.islands(state.dashboard) do
      spans = Enum.map(island.segs, fn {role, text} -> {text, Map.fetch!(styles, role)} end)
      {spans, island.key}
    end
  end

  # Walks the island cells left to right — each island costs its content
  # plus the two `┘`/`└` connectors, back to back with no separator — and
  # returns the key the island covering 0-based column x stands for, or
  # nil when x lands on the chrome filler. Widths come from the islands
  # themselves (no styling needed), so the pure test drives it with a
  # bare dashboard state.
  defp strip_key_at(state, x) when is_integer(x) and x >= 0 do
    Dashboard.islands(state.dashboard)
    |> Enum.reduce_while({nil, 0}, fn island, {_hit, cursor} ->
      width =
        2 + Enum.sum(Enum.map(island.segs, fn {_role, text} -> Helpers.text_width(text) end))

      if x in cursor..(cursor + width - 1) do
        {:halt, {island.key, cursor}}
      else
        {:cont, {nil, cursor + width}}
      end
    end)
    |> elem(0)
  end

  defp strip_key_at(_state, _x), do: nil

  # One full-width chrome bar: keycap ISLANDS (each a span group — the
  # unit of truncation), then `─` to the terminal edge. An island that
  # does not fit is dropped WHOLE, never half-drawn (btop truncates bars
  # the same way). The footer flash is reserved FIRST: a min-size
  # refusal must survive any width — the keys give way, the error never
  # does. The filler always closes the row at exactly `width` cells.
  defp chrome_bar(island_groups, flash, width, styles) do
    flash_span =
      case flash do
        nil -> []
        msg -> [{"  " <> msg, styles.err}]
      end

    flash_width =
      Enum.sum(Enum.map(flash_span, fn {text, _style} -> Helpers.text_width(text) end))

    budget = width - flash_width

    {visible, used} =
      Enum.reduce_while(island_groups, {[], 0}, fn group, {acc, used} ->
        w = Enum.sum(Enum.map(group, fn {text, _style} -> Helpers.text_width(text) end))

        if used + w > budget do
          {:halt, {acc, used}}
        else
          {:cont, {acc ++ group, used + w}}
        end
      end)

    visible ++ flash_span ++ [{String.duplicate("─", max(width - used - flash_width, 0)), styles.chrome}]
  end

  defp body_frame(%{op: {kind, sub}}, _dims), do: op_module(kind).view(sub)

  # The help reference renders as a boxed scrollable text view (↑↓ /
  # pgup/pgdn + the border block scrollbar) so nothing clips; the paged
  # overlay lands with the overlay lane.
  defp body_frame(%{op: nil, help: true} = state, dims) do
    styles = theme_styles(state)
    view = Map.get(state.text_views, :help) || TextView.init(Enum.join(Help.lines(), "\n"))

    TextView.bordered_view(view, dims, %{
      title: [{"?", styles.keycap}, {"help", styles.text}],
      border: styles.chrome,
      shortcut: styles.shortcut,
      chrome: styles.chrome,
      thumb: styles.shortcut
    })
  end

  # The one dashboard: whatever the layout answers for the visible set is
  # composed straight onto the body frame — boxes, not tabs.
  defp body_frame(%{op: nil} = state, dims), do: dashboard_frame(state, dims)

  defp dashboard_frame(state, dims) do
    styles = theme_styles(state)

    state.dashboard
    |> Dashboard.layout(dims)
    |> Enum.reduce(Helpers.frame([], dims), fn {box, rect}, frame ->
      Helpers.compose(frame, rect, &deep_box_frame(state, styles, box, &1))
    end)
  end

  # A drilled box swaps its pane for the deep view (§1.6): the
  # capabilities browser in its grown box, plan/diff as full-dashboard
  # read zooms. Every other box renders its summary.
  defp deep_box_frame(state, styles, box, dims) do
    case {Dashboard.expansion(state.dashboard), box} do
      {:capabilities, :capabilities} -> capabilities_drill(state, styles, dims)
      {zoom, pane} when zoom in [:plan, :diff] and zoom == pane -> zoom_pane(state, styles, box, dims)
      _summary -> box_frame(state, styles, box, dims)
    end
  end

  # The in-box tree drill: the browser's own pane layout inside the
  # grown box 2 (the Proc::y+8 view).
  defp capabilities_drill(state, styles, dims) do
    styles =
      Map.merge(styles, %{title: [{keycap(2), styles.keycap}, {"capabilities", styles.text}]})

    CapabilitiesBrowser.view(state.caps, dims, styles)
  end

  # The read zoom: the box's full render text in a bordered scrollable
  # pane filling the dashboard rect — the old read screens, retargeted
  # to in-place deep views. Without a cached read the summary box is the
  # honest zoom content.
  defp zoom_pane(state, styles, box, dims) do
    case Map.get(state.cache, box) do
      {:ok, envelope} ->
        renderer = if box == :plan, do: &Render.core_plan/1, else: &Render.core_diff/1
        view = Map.get(state.text_views, :"#{box}_zoom") || TextView.init(renderer.(envelope))

        TextView.bordered_view(view, dims, %{
          title: [
            {keycap(String.to_integer(Dashboard.box_number(box))), styles.keycap},
            {Atom.to_string(box), styles.text}
          ],
          border: Map.fetch!(styles, :"border_#{box}"),
          shortcut: styles.shortcut,
          chrome: styles.chrome,
          thumb: styles.shortcut
        })

      _no_read ->
        box_frame(state, styles, box, dims)
    end
  end

  defp zoom_text_view(state, id) do
    box = if id == :plan_zoom, do: :plan, else: :diff

    case Map.get(state.cache, box) do
      {:ok, envelope} ->
        renderer = if box == :plan, do: &Render.core_plan/1, else: &Render.core_diff/1
        TextView.init(renderer.(envelope))

      _no_read ->
        TextView.init("")
    end
  end

  # The zoomable box under a body point, if any (dashboard coordinates).
  defp box_at(%{dashboard: dash, dimensions: {width, height}}, x, y) do
    layout = Dashboard.layout(dash, {width, height - 2})

    Enum.find_value(layout, fn {box, {bx, by, bw, bh}} ->
      if x >= bx and x < bx + bw and y >= by and y < by + bh, do: box
    end)
  end

  defp box_frame(state, styles, :engine, dims), do: engine_box(state, styles, dims)
  defp box_frame(state, styles, :capabilities, dims), do: caps_box(state, styles, dims)
  defp box_frame(state, styles, :journal, dims), do: journal_box(state, styles, dims)
  defp box_frame(state, styles, :plan, dims), do: plan_box(state, styles, dims)
  defp box_frame(state, styles, :diff, dims), do: diff_box(state, styles, dims)
  defp box_frame(state, styles, :status, dims), do: status_box(state, styles, dims)

  @doc """
  btop's superscript keycap digit (btop_draw.cpp:87 Symbols::superscript):
  0-9 render as ⁰ ¹ ² ³ ⁴-⁹, values outside clamp into 0-9. Titles use the
  exact btop no-space construction `┐<keycap><title>┌` (btop CursesRenderer
  title handling); the plain-digit form is a narrow-TTY concern, never the
  default.
  """
  @spec keycap(integer()) :: String.t()
  def keycap(n) when is_integer(n) do
    # btop_draw.cpp:87 superscript table (Symbols::superscript.at).
    digits = ["⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹"]
    Enum.fetch!(digits, n |> max(0) |> min(9))
  end

  defp disconnected?(message) do
    text = message_text(message)
    String.contains?(text, "daemon_unavailable") or String.contains?(text, "daemon_died")
  end

  # Wire failures may carry non-binary reasons (a raised exception folded
  # by the runtime's async envelope); every render path normalizes first.
  defp message_text(message) when is_binary(message), do: message
  defp message_text(message), do: inspect(message)

  defp engine_box(state, styles, dims) do
    Box.frame(engine_rows(state, styles), dims,
      border_style: styles.border_engine,
      title: [{keycap(1), styles.keycap}, {"engine", styles.text}],
      right: daemon_badge(state, styles)
    )
  end

  defp journal_box(state, styles, dims) do
    Box.frame(journal_rows(state, styles), dims,
      border_style: styles.border_journal,
      title: [{keycap(3), styles.keycap}, {"journal", styles.text}],
      right: journal_counter(state, styles)
    )
  end

  # The journal box's border counter: the journal revision — the same
  # fact the old status read pane showed (§2.1 box 3).
  defp journal_counter(%{cache: %{status: {:ok, status}}}, styles) do
    case status["journal"] do
      journal when is_map(journal) ->
        [{"rev #{Map.get(journal, "revision", "?")}", styles.chrome}]

      _other ->
        []
    end
  end

  defp journal_counter(_state, _styles), do: []

  defp plan_box(state, styles, dims) do
    Box.frame(plan_rows(state, styles), dims,
      border_style: styles.border_plan,
      title: [{keycap(4), styles.keycap}, {"plan", styles.text}],
      right: pending_badge(state, :plan, styles)
    )
  end

  defp diff_box(state, styles, dims) do
    Box.frame(diff_rows(state, styles), dims,
      border_style: styles.border_diff,
      title: [{keycap(5), styles.keycap}, {"diff", styles.text}],
      right: pending_badge(state, :diff, styles)
    )
  end

  # The status probe's deep rows (§2.1 box 6): the host facts the daemon
  # tab carried (destination, platform, graph order) plus the journal's
  # generation/revision pair; the border read badge keeps the sync
  # verdict from the diff wire.
  defp status_box(state, styles, dims) do
    Box.frame(status_rows(state, styles), dims,
      border_style: styles.border_status,
      title: [{keycap(6), styles.keycap}, {"status", styles.text}],
      right: status_badge(state, styles)
    )
  end

  defp status_journal(%{cache: %{status: {:ok, status}}}), do: status["journal"]
  defp status_journal(_state), do: nil

  # The status box's border badge: journal generation plus the sync
  # verdict from the diff wire (the old status read pane's badge).
  defp status_badge(state, styles) do
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

  defp status_rows(%{cache: %{status: {:ok, wire}}} = _state, styles) do
    journal = wire["journal"]

    generation_row =
      case journal do
        j when is_map(j) ->
          label_row("generation", "#{j["generation"]}", styles)

        _other ->
          label_row("generation", "none — nothing applied yet", styles)
      end

    revision_row =
      case journal do
        j when is_map(j) ->
          label_row("revision", "rev #{Map.get(j, "revision", "?")}", styles)

        _other ->
          []
      end

    [
      label_row("destination", Map.get(wire, "destination", "?"), styles),
      label_row("platform", Map.get(wire, "platform", "?"), styles),
      label_row("graph order", "#{length(wire["graph_order"] || [])} resolved", styles),
      generation_row,
      revision_row
    ]
  end

  # Read failures split into the transport shape (daemon unreachable —
  # the recovery hint names the start command) and every other failure
  # (the verbatim message; r retries either way).
  defp status_rows(%{cache: %{status: {:error, message}}}, styles) do
    if disconnected?(message) do
      [
        [{" daemon unreachable", styles.err}],
        [{" " <> message_text(message), styles.err}],
        [{" start it with `workstation daemon` — retry with r", styles.inactive}]
      ]
    else
      [
        [{" read failed", styles.err}],
        [{" " <> message_text(message), styles.err}],
        [{" retry with r", styles.inactive}]
      ]
    end
  end

  defp status_rows(_state, styles), do: [label_row("status", "loading…", styles)]

  # The actions box: per-domain block meters over the collected desired
  # state; the bottom border doubles as the home buttonbar (apply/update
  # appear exactly when their key works)."""
  defp caps_box(state, styles, dims) do
    Box.frame(caps_rows(state, styles), dims,
      border_style: styles.border_capabilities,
      title: [{keycap(2), styles.keycap}, {"capabilities", styles.text}],
      buttons: [[{"a", styles.shortcut}, {" apply", styles.text}]] ++
                 u_button(state, styles) ++
                 [[{"r", styles.shortcut}, {" refresh", styles.text}]]
    )
  end

  # `u update` rides the buttonbar only while the update is available —
  # the same honesty rule as the old keys line (a key that does nothing
  # must not be advertised).
  defp u_button(%{update_hint: hint}, styles) when hint != nil do
    [[{"u", styles.shortcut}, {" update", styles.text}]]
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
          # The removed header facts line's gen/rev pair lives here now:
          # the journal box's first row reads "generation … · rev …".
          label_row(
            "generation",
            "#{journal["generation"]} · rev #{Map.get(journal, "revision", "?")}",
            styles
          ),
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

  defp footer_frame(state, {width, height}) do
    # Global footer keeps the frame keys only (btop grammar: island bar,
    # glowing caps): the digit toggles, the preset cycle, help, quit.
    # The toggle gate's inline refusal rides the bar's tail (btop's
    # SizeError toast, least-invasive): one keypress long, then gone.
    styles = theme_styles(state)

    buttons = [
      {"1-6", " toggle"},
      {"p/P", " layout"},
      {"?", " help"},
      {"q", " quit"}
    ]

    line =
      buttons
      |> Enum.map(fn {key, label} ->
        [{"┘", styles.chrome}, {key, styles.shortcut}, {label, Style.new()}, {"└", styles.chrome}]
      end)

    Helpers.frame([chrome_bar(line, state.flash, width, styles)], {width, height})
  end

  # The resolved btop-grammar role styles for one render: every visual
  # claim routes through the theme envelope roles (never literals).
  # Titles read the near-white text role, bold (btop's title treatment);
  # keycaps ride the shortcut role, bold. Border roles are per-domain
  # (docs/theme.md): engine/plan blue, journal/status green,
  # capabilities yellow, diff red.
  defp theme_styles(state) do
    %{
      accent: role_style(state, :accent, fallback: Style.new(attrs: [:bold]), attrs: [:bold]),
      ok: role_style(state, :ok, fallback: :green),
      warn: role_style(state, :warn, fallback: :yellow),
      err: role_style(state, :err, fallback: :red),
      text: role_style(state, :text, fallback: :white, attrs: [:bold]),
      keycap: role_style(state, :shortcut, fallback: Style.new(attrs: [:bold]), attrs: [:bold]),
      shortcut: role_style(state, :shortcut, fallback: Style.new(attrs: [:bold])),
      inactive: role_style(state, :inactive, fallback: :bright_black),
      chrome: role_style(state, :chrome, fallback: :bright_black),
      ramp_start: role_style(state, :ramp_start, fallback: :green),
      ramp_mid: role_style(state, :ramp_mid, fallback: :yellow),
      ramp_end: role_style(state, :ramp_end, fallback: :red),
      border_engine: role_style(state, :border_engine, fallback: :blue),
      border_journal: role_style(state, :border_journal, fallback: :green),
      border_capabilities: role_style(state, :border_capabilities, fallback: :yellow),
      border_plan: role_style(state, :border_plan, fallback: :blue),
      border_diff: role_style(state, :border_diff, fallback: :red),
      border_status: role_style(state, :border_status, fallback: :green),
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
