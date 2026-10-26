defmodule Workstation.CLI.TUI.Shell do
  @moduledoc """
  The workstation TUI application shell — the one dashboard. One Elm root
  (the same `TermUI.Elm` contract as the retired apply/update screens)
  owning the global chrome: the four-box dashboard as the entire app — the
  boxes' own superscript titles advertise their toggle digits — and a
  footer with the global keys (btop-ia-spec §2). The mosaic IS the app —
  there are no tabs:

    * digits 1-4 toggle the boxes (`Shell.Dashboard.toggle_box`:
      flip membership, min-size gate, re-tile);
    * p/P cycle the presets (full mosaic / audit / minimal, wrap-around);
    * `?` toggles the help reference (a boxed scrollable pane — the
      floating-paged variant is a recorded deviation).

  All reads go through the read plane (`Workstation.CLI.Output.evaluate/2`,
  the baked eval report served in-process); the shell never mutates
  anything — the write plane lives in the nix substrate
  (`workstation-switch`), and this dashboard is the resident read surface.
  The `:load` seam is an injected
  fun, so tests replay fixed wire streams with no filesystem involved
  (deterministic replay).

  Data states are explicit per box: loading (read in flight), data,
  error. Keys are documented in the help pane.
  """

  use TermUI.Elm

  alias TermUI.{Command, Event, Layout, Style}
  alias TermUI.Widget.Helpers

  alias Workstation.CLI.{Capabilities, Output, Render}
  alias Workstation.CLI.TUI.Theme
  alias Workstation.CLI.TUI.Shell.{Box, CapabilitiesBrowser, Dashboard, Help, TextView}

  # The dashboard's wires: every box subscribes to the same reads the old
  # tabs did — the placement changed, the data seams did not (§2.5).
  @wires [:status, :plan]

  ## production entry

  @doc """
  Router entry for the bare `workstation` verb: resolve the theme from the
  base token palette and run this shell on the TTY backend. `TermUI`
  injects `:dimensions` at init.
  """
  def run(opts) do
    home = Keyword.fetch!(opts, :home)

    Workstation.CLI.TUI.run(__MODULE__,
      destination: home,
      appearance: Keyword.get(opts, :appearance, :dark),
      preset: Keyword.get(opts, :preset, 0)
    )
  end

  @type load_state :: nil | :loading | {:ok, map()} | {:error, String.t()}

  defstruct [
    :destination,
    :theme,
    :dimensions,
    :cache,
    :load,
    :caps,
    :caps_env,
    :text_views,
    :toast_ms,
    :now,
    # The six-box dashboard state: visible set + preset tracking.
    dashboard: Dashboard.new(),
    # The toggle gate's inline footer error (btop's SizeError toast);
    # lives exactly one unhandled keypress.
    flash: nil,
    # The help reference pane (? toggles; a boxed scrollable view — the
    # floating-paged variant is a recorded deviation).
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
          toast_ms: pos_integer(),
          dashboard: Dashboard.t(),
          flash: String.t() | nil,
          help: boolean()
        }

  @doc "The read wires behind the dashboard's boxes."
  @spec read_load(atom(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def read_load(command, destination) do
    case Output.evaluate(command, destination) do
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
      load: Keyword.get(opts, :load, &read_load(&1, Keyword.fetch!(opts, :destination))),
      caps: CapabilitiesBrowser.init(nil),
      caps_env: nil,
      text_views: %{},
      toast_ms: Keyword.get(opts, :toast_ms, 5_000),
      # Render clock: injected so ramp (staleness) renders are deterministic
      # under replay; production takes the boot time exactly once.
      now: Keyword.get(opts, :now, DateTime.utc_now()),
      # Boot layout pin (the bare verb's `--preset N`, default the full
      # mosaic): the preset membership is the visible set, the bond live.
      dashboard: Dashboard.new(Keyword.get(opts, :preset, 0))
    }

    # Boot effects: the dashboard's reads — all asynchronous; the
    # first frame paints immediately in the loading state.
    {state, commands} = load_commands(state, @wires, false)
    {state, commands}
  end

  @doc "Same event normalization contract as the read screens."
  @spec event_to_msg(Event.t(), t()) :: {:msg, term()} | :ignore
  @impl TermUI.Elm
  def event_to_msg(%Event.Text{text: "↑"}, _state), do: {:msg, {:key, :up}}
  def event_to_msg(%Event.Text{text: "↓"}, _state), do: {:msg, {:key, :down}}
  def event_to_msg(%Event.Text{text: text}, _state), do: {:msg, {:text, text}}

  def event_to_msg(%Event.Key{key: key}, _state), do: {:msg, {:key, key}}

  def event_to_msg(%Event.Resize{width: width, height: height}, _state),
    do: {:msg, {:resize, width, height}}

  # Mouse: the wheel reuses the pane scroll keys; everything else is
  # inert. Coordinates are 0-based cells (term_ui contract). There is no
  # top strip — the boxes' own superscript titles advertise their toggle
  # digits and the footer carries p/P · help · quit.
  def event_to_msg(%Event.Mouse{action: :scroll_up}, _state), do: {:msg, {:key, :up}}
  def event_to_msg(%Event.Mouse{action: :scroll_down}, _state), do: {:msg, {:key, :down}}

  # A left click inside a zoomable box toggles its deep view (§2.5:
  # click inside a zoomable box = zoom); the point is addressed in body
  # coordinates (the dashboard starts at row 0; the footer rides the
  # last row).
  def event_to_msg(%Event.Mouse{action: :press, button: :left, x: x, y: y} = event, state)
      when y >= 0 do
    case box_at(state, x, y) do
      box when box in [:capabilities, :plan] -> {:msg, {:box_click, box}}
      _other -> {:msg, event}
    end
  end

  def event_to_msg(%Event.Mouse{}, _state), do: :ignore

  def event_to_msg(_event, _state), do: :ignore

  @impl TermUI.Elm
  ## -- dashboard mode ---------------------------------------------------

  # q quits the app (the footer's documented quit key).
  def update({:text, "q"}, state), do: {state, [Command.shutdown()]}

  # Resize re-tiles the dashboard from the visible set and clears preset
  # tracking (§1.2 — a box resize breaks the preset bond exactly like a
  # manual toggle). No view routing: the boxes re-clip at render time.
  def update({:resize, width, height}, state) do
    %{
      state
      | dimensions: {width, height},
        dashboard: Dashboard.clear_tracking(state.dashboard),
        flash: nil
    }
  end

  # Wire results land in the cache and refresh the derived views.
  def update({:wire_loaded, command, result}, state) do
    state =
      %{state | cache: Map.put(state.cache, command, result)}
      |> refresh_derived(command, result)

    {state, []}
  end

  ## -- dashboard keys -----------------------------------------------------

  # Digits 1-4 toggle dashboard boxes (Config::toggle_box semantics:
  # flip membership, min-size gate, re-tile); 0 and 5+ are inert (btop
  # refuses out-of-range digits the same way — they fall through to the
  # catch-all). A min-size refusal surfaces as the footer's inline flash.
  def update({:text, digit}, state) when digit in ~w(1 2 3 4) do
    box = Dashboard.box_for_key(digit)

    case Dashboard.toggle_box(state.dashboard, box, elem(state.dimensions, 0)) do
      {:ok, dashboard} ->
        %{state | dashboard: dashboard, flash: nil}

      {:error, min} ->
        %{state | flash: "#{box} needs >= #{min} columns"}
    end
  end

  # p/P cycle the presets (next/previous, wrap-around; §2.2).
  def update({:text, "p"}, state),
    do: %{state | dashboard: Dashboard.cycle(state.dashboard, :next), flash: nil}

  def update({:text, "P"}, state),
    do: %{state | dashboard: Dashboard.cycle(state.dashboard, :prev), flash: nil}

  # ? toggles the help reference (a boxed scrollable view — the
  # floating-paged variant is a recorded deviation; §2.4 keeps the
  # symmetric open/close key).
  def update({:text, "?"}, state), do: %{state | help: not state.help, flash: nil}

  # r refreshes the dashboard's reads — force reload even when cached.
  def update({:text, "r"}, state) do
    {state, commands} = load_commands(state, @wires, true)
    {%{state | flash: nil}, commands}
  end

  ## -- in-box deep views (§1.6: drill/zoom never leave the dashboard) -----

  # Enter = the btop proc-detail key: expand the first visible zoomable
  # box in place (capabilities tree drill, plan read zoom); Enter
  # again restores the tiler (btop_input.cpp:462-484 — Enter toggles
  # show_detailed).
  def update({:key, :enter}, %{help: false} = state) do
    case Dashboard.expansion(state.dashboard) do
      nil ->
        box = Enum.find(~w(capabilities plan)a, &Dashboard.visible?(state.dashboard, &1))

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
  def update({:key, :escape}, %{help: true} = state),
    do: %{state | help: false, flash: nil}

  def update({:key, :escape}, state) do
    if Dashboard.expansion(state.dashboard) != nil do
      %{state | dashboard: Dashboard.contract(state.dashboard), flash: nil}
    else
      state
    end
  end

  # A click inside a zoomable box toggles ITS deep view (§2.5: click
  # inside a zoomable box = zoom, the proc-detail analog); clicks do not
  # steal the deep view from the box that owns it.
  def update({:box_click, box}, %{dashboard: dash} = state) do
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

  def update({:key, key}, %{help: false} = state) when key in @nav_keys do
    case scroll_target(state) do
      {:zoom, id} ->
        zoom_scroll(state, id, key)

      {:browser, _caps} ->
        %{state | caps: CapabilitiesBrowser.update({:key, key}, state.caps), flash: nil}

      nil ->
        if state.flash != nil, do: update({:key, key}, %{state | flash: nil}), else: state
    end
  end

  # Scroll keys ride the help reference while it is open; every other
  # message is ignored (the boxes are static summaries until the overlay
  # lane adds their scrollable deep views).
  def update(message, %{help: true, text_views: views} = state) do
    view = Map.get(views, :help) || TextView.init(Enum.join(Help.lines(), "\n"))
    %{state | text_views: Map.put(views, :help, TextView.update(message, view))}
  end

  # Any unhandled key clears the footer flash: the inline error's
  # lifetime is exactly one keypress — the layout did not change under
  # it. Re-dispatch on the cleared state; every real clause sits above.
  def update(message, %{flash: flash} = state) when flash != nil,
    do: update(message, %{state | flash: nil})

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

    [body, footer] = Layout.column(Layout.new({width, height}), [:fill, 1])

    frame = Helpers.frame([], {width, height})

    frame
    |> Helpers.compose(body, &body_frame(state, &1))
    |> compose_footer(footer, state)
  end

  defp compose_footer(frame, footer, state),
    do: Helpers.compose(frame, footer, &footer_frame(state, &1))

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
  defp refresh_derived(state, command, {:ok, _wire}) when command in [:status, :plan] do
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
      expansion when expansion in [:plan] ->
        {:zoom, :"#{expansion}_zoom"}

      _expansion ->
        if Dashboard.visible?(dash, :capabilities), do: {:browser, state.caps}, else: nil
    end
  end

  defp zoom_scroll(%{text_views: views} = state, id, key) do
    view = Map.get(views, id) || zoom_text_view(state, id)
    %{state | text_views: Map.put(views, id, TextView.update({:key, key}, view))}
  end

  ## rendering

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

  # The help reference renders as a boxed scrollable text view (↑↓ /
  # pgup/pgdn + the border block scrollbar) so nothing clips; the paged
  # overlay lands with the overlay lane.
  defp body_frame(%{help: true} = state, dims) do
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
  defp body_frame(state, dims), do: dashboard_frame(state, dims)

  defp dashboard_frame(state, dims) do
    styles = theme_styles(state)

    state.dashboard
    |> Dashboard.layout(dims)
    |> Enum.reduce(Helpers.frame([], dims), fn {box, rect}, frame ->
      Helpers.compose(frame, rect, &deep_box_frame(state, styles, box, &1))
    end)
  end

  # A drilled box swaps its pane for the deep view (§1.6): the
  # capabilities browser in its grown box, plan as the full-dashboard
  # read zoom. Every other box renders its summary.
  defp deep_box_frame(state, styles, box, dims) do
    case {Dashboard.expansion(state.dashboard), box} do
      {:capabilities, :capabilities} -> capabilities_drill(state, styles, dims)
      {zoom, pane} when zoom in [:plan] and zoom == pane -> zoom_pane(state, styles, box, dims)
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
        renderer = &Render.core_plan/1
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

  defp zoom_text_view(state, :plan_zoom) do
    case Map.get(state.cache, :plan) do
      {:ok, envelope} -> TextView.init(Render.core_plan(envelope))
      _no_read -> TextView.init("")
    end
  end

  # The zoomable box under a body point, if any. The dashboard spans
  # body rows 0..height-2 (the footer rides the last terminal row) and
  # the walk is TOPMOST-first — the layout list is draw order (bottom to
  # top), so a click inside an expanded box's overlay region hits the
  # box that owns the pixels, not the neighbor it covers.
  defp box_at(%{dashboard: dash, dimensions: {width, height}}, x, y) do
    layout = Dashboard.layout(dash, {width, height - 1})

    layout
    |> Enum.reverse()
    |> Enum.find_value(fn {box, {bx, by, bw, bh}} ->
      if x >= bx and x < bx + bw and y >= by and y < by + bh, do: box
    end)
  end

  defp box_frame(state, styles, :engine, dims), do: engine_box(state, styles, dims)
  defp box_frame(state, styles, :capabilities, dims), do: caps_box(state, styles, dims)
  defp box_frame(state, styles, :plan, dims), do: plan_box(state, styles, dims)
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

  # Wire failures may carry non-binary reasons (a raised exception folded
  # by the runtime's async envelope); every render path normalizes first.
  defp message_text(message) when is_binary(message), do: message
  defp message_text(message), do: inspect(message)

  defp engine_box(state, styles, dims) do
    Box.frame(engine_rows(state, styles), dims,
      border_style: styles.border_engine,
      title: [{keycap(1), styles.keycap}, {"engine", styles.text}],
      right: read_badge(state, styles)
    )
  end

  defp plan_box(state, styles, dims) do
    Box.frame(plan_rows(state, styles), dims,
      border_style: styles.border_plan,
      title: [{keycap(3), styles.keycap}, {"plan", styles.text}],
      right: pending_badge(state, :plan, styles)
    )
  end

  # The status read's deep rows (§2.1 box 4): the host facts (destination,
  # platform, graph order).
  defp status_box(state, styles, dims) do
    Box.frame(status_rows(state, styles), dims,
      border_style: styles.border_status,
      title: [{keycap(4), styles.keycap}, {"status", styles.text}]
    )
  end

  defp status_rows(%{cache: %{status: {:ok, wire}}}, styles) do
    [
      label_row("destination", Map.get(wire, "destination", "?"), styles),
      label_row("platform", Map.get(wire, "platform", "?"), styles),
      label_row(
        "declared",
        "#{length(wire["capabilityOrder"] || [])} capabilities · " <>
          "#{(wire["counts"] || %{})["fileTargets"] || 0} file targets",
        styles
      )
    ]
  end

  # A read failure renders its verbatim message; r retries.
  defp status_rows(%{cache: %{status: {:error, message}}}, styles) do
    [
      [{" read failed", styles.err}],
      [{" " <> message_text(message), styles.err}],
      [{" retry with r", styles.inactive}]
    ]
  end

  defp status_rows(_state, styles), do: [label_row("status", "loading…", styles)]

  # The actions box: per-domain block meters over the collected desired
  # state; the bottom border doubles as the refresh buttonbar.
  defp caps_box(state, styles, dims) do
    Box.frame(caps_rows(state, styles), dims,
      border_style: styles.border_capabilities,
      title: [{keycap(2), styles.keycap}, {"capabilities", styles.text}],
      buttons: [[{"r", styles.shortcut}, {" refresh", styles.text}]]
    )
  end

  # `label      value` body row: the label reads inactive (dimmed
  # chrome), the value carries its own role span (or plain text). The
  # pad guarantees a separator space after the longest label.
  defp label_row(label, value, styles) do
    pad = max(12, String.length(label) + 3)

    [{" " <> String.pad_trailing(label <> ":", pad), styles.inactive}, as_value(value)]
  end

  defp as_value(value) when is_binary(value), do: {value, Style.new()}
  defp as_value({text, _style} = span) when is_binary(text), do: span

  # Read-state badge on the engine box's top border: one state glyph, one
  # role color (accent read answered, err read failed, inactive loading).
  defp read_badge(state, styles) do
    case Map.get(state.cache, :status) do
      {:ok, _wire} -> [{"● report", styles.accent}]
      {:error, _message} -> [{"● unreadable", styles.err}]
      _loading -> [{"● loading", styles.inactive}]
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
      label_row(
        "capabilities",
        "#{length(wire["capabilityOrder"] || [])} declared " <>
          "(#{(wire["counts"] || %{})["fileTargets"] || 0} file targets)",
        styles
      )
    ]
  end

  defp engine_rows(%{cache: %{status: {:error, message}}}, styles) do
    [label_row("engine", {message_text(message), styles.err}, styles)]
  end

  defp engine_rows(_state, styles), do: [label_row("engine", "loading…", styles)]

  defp plan_rows(%{cache: %{plan: {:ok, plan}}}, styles) do
    declared = plan["declared"] || %{}
    files = length(declared["fileTargets"] || [])
    claims = length(declared["claimTargets"] || [])
    retire = length(declared["retire"] || [])

    [
      label_row("generation", Map.get(plan, "generation", "?"), styles),
      label_row("declared", "#{files} file targets · #{claims} tree claims", styles),
      label_row("retire", "#{retire}", styles)
    ]
  end

  defp plan_rows(%{cache: %{plan: {:error, message}}}, styles) do
    [label_row("plan", {message_text(message), styles.err}, styles)]
  end

  defp plan_rows(_state, styles), do: [label_row("plan", "loading…", styles)]

  defp caps_rows(%{caps_env: %{} = envelope}, styles) do
    domains = envelope["domains"] || []
    max_files = domains |> Enum.map(&(&1["files"] || 0)) |> Enum.max(fn -> 0 end)

    [
      label_row(
        "rollup",
        "#{length(domains)} domains · #{Capabilities.total_files(envelope)} files · " <>
          "#{Capabilities.total_planned(envelope)} would change",
        styles
      )
    ] ++
      Enum.map(domains, &domain_meter_row(&1, max_files, styles))
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

  defp footer_frame(state, {width, height}) do
    # Global footer keeps the frame keys only (btop grammar: island bar,
    # glowing caps): the digit toggles, the preset cycle, help, quit.
    # The toggle gate's inline refusal rides the bar's tail (btop's
    # SizeError toast, least-invasive): one keypress long, then gone.
    styles = theme_styles(state)

    buttons = [
      {"1-4", " toggle"},
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
  # (docs/theme.md): engine/plan blue, status green,
  # capabilities yellow.
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
      border_capabilities: role_style(state, :border_capabilities, fallback: :yellow),
      border_plan: role_style(state, :border_plan, fallback: :blue),
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
