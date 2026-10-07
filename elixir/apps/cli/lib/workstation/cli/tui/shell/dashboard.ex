defmodule Workstation.CLI.TUI.Shell.Dashboard do
  @moduledoc """
  The one dashboard — the mosaic IS the app (btop-ia-spec §2.1). Six
  engine-owned boxes re-tiled by toggles and presets exactly like btop's
  `shown_boxes`:

    * `1 engine` — engine identity + liveness (the daemon tab's rows and
      `●` badge live here now);
    * `2 capabilities` — domain rollup + block meters + the a/u/r
      buttonbar;
    * `3 journal` — generation/revision/applied-at (the journal read);
    * `4 plan` — the plan summary rows;
    * `5 diff` — the diff summary rows;
    * `6 status` — the status probe's deep rows (destination, platform,
      graph order, generation/revision).

  Digits **1-6 toggle** box visibility (`Config::toggle_box` semantics:
  flip membership, min-size gate refuses with an error, re-tile) and any
  toggle dissolves preset tracking (`current_preset.reset()`); `0` and
  `7+` are inert. Presets cycle with p/P (next/previous, wrap-around) and
  preset 0 — the full mosaic — is engine-seeded, never user data
  (§2.2). Below the mosaic width the boxes render through the stacked
  priority-fill tiler (the responsive renderer a preset's intent keeps).

  The module is pure state + geometry: it knows nothing about styles or
  frames. The strip's island tokens (`islands/1`) carry role-tagged
  segments the shell resolves through the theme (roles-are-the-API), and
  the same tokens drive the mouse hit-test so the strip has exactly one
  spelling for click = keypress.
  """

  alias TermUI.Layout

  @enforce_keys [:visible, :preset]
  defstruct [:visible, :preset]

  @type box :: :engine | :capabilities | :journal | :plan | :diff | :status
  @type preset_id :: 0 | 1 | 2
  @type t :: %__MODULE__{visible: MapSet.t(box()), preset: preset_id() | nil}

  # Box order is the strip order; the digit keys address it 1-based.
  @boxes [:engine, :capabilities, :journal, :plan, :diff, :status]

  @box_keys %{
    "1" => :engine,
    "2" => :capabilities,
    "3" => :journal,
    "4" => :plan,
    "5" => :diff,
    "6" => :status
  }

  # Preset strings in the btop format (§2.2), engine-seeded preset 0
  # always first: 0 the full mosaic, 1 the audit focus (plan+diff tall
  # top, engine+journal compressed to a bottom band), 2 minimal
  # (health + what-changed-when).
  @presets %{
    0 => [:engine, :capabilities, :journal, :plan, :diff, :status],
    1 => [:engine, :journal, :plan, :diff],
    2 => [:engine, :journal]
  }

  # The one hard minimum (btop's Term::get_min_size gate): the
  # capabilities box must be able to host its in-box drill-down browser.
  # Every other box elides content inside its (still closed) borders, so
  # it toggles freely at any width.
  @min_widths %{capabilities: 62}

  @doc "Engine-seeded start state: preset 0, the full mosaic."
  @spec new() :: t()
  def new, do: %__MODULE__{visible: MapSet.new(@presets[0]), preset: 0}

  @doc "The box set in strip order."
  @spec boxes() :: [box()]
  def boxes, do: @boxes

  @doc "The preset membership table (btop preset strings, decoded)."
  @spec presets() :: %{preset_id() => [box()]}
  def presets, do: @presets

  @doc "A digit strip key → its box, or nil for inert keys (0, 7+)."
  @spec box_for_key(String.t()) :: box() | nil
  def box_for_key(key), do: Map.get(@box_keys, key)

  @spec visible?(t(), box()) :: boolean()
  def visible?(%__MODULE__{visible: visible}, box), do: MapSet.member?(visible, box)

  @doc """
  `Config::toggle_box`: flip membership and re-tile. Toggling a box ON
  that cannot claim its minimum width refuses with the failing minimum
  (btop's SizeError → the shell surfaces it as an inline footer error)
  and the layout stays put. Either outcome dissolves preset tracking.
  """
  @spec toggle_box(t(), box(), pos_integer()) :: {:ok, t()} | {:error, pos_integer()}
  def toggle_box(%__MODULE__{visible: visible} = dash, box, width) do
    cond do
      MapSet.member?(visible, box) ->
        {:ok, %{dash | visible: MapSet.delete(visible, box), preset: nil}}

      width < min_width(box) ->
        {:error, min_width(box)}

      true ->
        {:ok, %{dash | visible: MapSet.put(visible, box), preset: nil}}
    end
  end

  @doc "The box's minimum columns (0 = elides at any width)."
  @spec min_width(box()) :: non_neg_integer()
  def min_width(box), do: Map.get(@min_widths, box, 0)

  @doc """
  btop preset cycling: p next, P previous, wrap-around. A dissolved
  tracker (after a manual toggle or a resize) seeds `p` from before the
  list — the next p applies preset 0 — and `P` wraps from the end.
  """
  @spec cycle(t(), :next | :prev) :: t()
  def cycle(%__MODULE__{preset: preset}, direction) do
    from =
      case {preset, direction} do
        {nil, :next} -> -1
        {nil, :prev} -> 0
        {id, _} -> id
      end

    step = if direction == :next, do: 1, else: -1
    next = Integer.mod(from + step, map_size(@presets))
    %__MODULE__{visible: MapSet.new(Map.fetch!(@presets, next)), preset: next}
  end

  @doc "A box resize re-tiles from the visible set and clears tracking (§1.2)."
  @spec clear_tracking(t()) :: t()
  def clear_tracking(%__MODULE__{} = dash), do: %{dash | preset: nil}

  @doc """
  Strip island tokens, one per box then the p/P cycle pair: `key` is the
  keypress the island stands for (click = keypress), `segs` are
  role-tagged spans — a visible box glows (`¹engine`: keycap + accent),
  a hidden box renders dimmed with its digit in brackets (`[4] plan`,
  the least-invasive superset of btop's nothing-for-hidden).
  """
  @spec islands(t()) :: [%{key: String.t(), segs: [{atom(), String.t()}]}]
  def islands(%__MODULE__{visible: visible}) do
    box_tokens =
      for {box, digit} <- Enum.with_index(@boxes, 1) do
        label = Atom.to_string(box)
        key = Integer.to_string(digit)

        if MapSet.member?(visible, box) do
          %{key: key, segs: [keycap: keycap(digit), accent: label]}
        else
          %{key: key, segs: [inactive: "[#{digit}] #{label}"]}
        end
      end

    box_tokens ++
      [
        %{key: "p", segs: [keycap: "p", text: " next"]},
        %{key: "P", segs: [keycap: "P", text: " prev"]}
      ]
  end

  defp keycap(digit), do: Workstation.CLI.TUI.Shell.keycap(digit)

  @type rect :: {x :: non_neg_integer(), y :: non_neg_integer(), width :: pos_integer(), height :: pos_integer()}

  # Slot mosaic (§2.2 preset 0 at width >= @mosaic_min_width): the 2x2
  # quadrants (engine|journal, plan|diff) plus the two full-width bottom
  # bands (capabilities, status). Each row lists its boxes left to
  # right; `:fill` rows take the surplus height, fixed rows claim their
  # band height.
  @slot_rows [
    {[:engine, :journal], :fill},
    {[:plan, :diff], :fill},
    {[:capabilities], 6},
    {[:status], 5}
  ]

  # Preset 1 audit: plan+diff take the tall top rows; engine+journal
  # compress into the bottom band (both boxes carry 3 body rows).
  @audit_rows [
    {[:plan, :diff], :fill},
    {[:engine, :journal], 5}
  ]

  # Preset 2 minimal: health + what-changed-when only.
  @minimal_rows [
    {[:engine, :journal], :fill}
  ]

  # Below the mosaic width the visible boxes stack full-width in
  # priority order (engine > journal > domains > plan/diff > status) on
  # bounded-fill tracks — the responsive renderer a preset's intent
  # keeps (§2.2).
  @mosaic_min_width 110

  @stack_order [:engine, :journal, :capabilities, :plan, :diff, :status]
  @stack_min_heights %{
    engine: 3,
    journal: 3,
    capabilities: 4,
    plan: 3,
    diff: 3,
    status: 4
  }

  @doc """
  Tile the dashboard: `[{box, rect}]` for the visible set at `{width,
  height}`. Presets 1/2 use their bespoke row structure at every width;
  everything else uses the slot mosaic at `>= #{@mosaic_min_width}`
  columns and the stacked priority renderer below it — preset 0 and a
  dissolved (custom) set alike.
  """
  @spec layout(t(), {pos_integer(), pos_integer()}) :: [{box(), rect()}]
  def layout(%__MODULE__{preset: preset, visible: visible}, dims) do
    {width, _height} = dims

    cond do
      preset == 1 -> tile(@audit_rows, visible, dims)
      preset == 2 -> tile(@minimal_rows, visible, dims)
      width >= @mosaic_min_width -> tile(@slot_rows, visible, dims)
      true -> stack(visible, dims)
    end
  end

  # One tile row per track; the row's visible boxes split it evenly.
  defp tile(rows, visible, {width, height}) do
    live =
      Enum.filter(rows, fn {boxes, _} ->
        Enum.any?(boxes, &MapSet.member?(visible, &1))
      end)

    case live do
      [] ->
        []

      live ->
        tracks = Enum.map(live, fn {_boxes, spec} -> row_track(spec) end)

        live
        |> Enum.zip(Layout.column(Layout.new({width, height}), tracks))
        |> Enum.flat_map(fn {{boxes, _spec}, rect} ->
          row_boxes(boxes, visible, rect)
        end)
    end
  end

  defp row_track(:fill), do: Layout.fill()
  defp row_track(band) when is_integer(band), do: Layout.fixed(band)

  defp row_boxes(boxes, visible, rect) do
    case Enum.filter(boxes, &MapSet.member?(visible, &1)) do
      [] ->
        []

      [only] ->
        [{only, rect}]

      pair ->
        [left, right] = Layout.row(rect, [Layout.percentage(50), Layout.fill()])
        Enum.zip(pair, [left, right])
    end
  end

  defp stack(visible, {width, height}) do
    shown = Enum.filter(@stack_order, &MapSet.member?(visible, &1))

    case shown do
      [] ->
        []

      shown ->
        tracks =
          Enum.map(shown, fn box ->
            Layout.bounded(Layout.fill(), min: Map.fetch!(@stack_min_heights, box))
          end)

        Enum.zip(shown, Layout.column(Layout.new({width, height}), tracks))
    end
  end
end
