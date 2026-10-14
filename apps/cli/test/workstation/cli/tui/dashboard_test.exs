defmodule Workstation.CLI.TUI.Shell.DashboardTest do
  # Pure state/geometry tests for the one-dashboard model (btop-ia-spec
  # §2.1-2.2): toggle semantics, preset cycling, tiling. No frames, no
  # styles — the shell renders what this module answers.
  use ExUnit.Case, async: true

  alias Workstation.CLI.TUI.Shell.Dashboard

  describe "new/0 seeds the engine state" do
    test "preset 0 with every box visible" do
      dash = Dashboard.new()

      assert dash.preset == 0
      assert Enum.all?(Dashboard.boxes(), &Dashboard.visible?(dash, &1))
    end
  end

  describe "toggle_box/3 (Config::toggle_box semantics)" do
    test "toggling a visible box off hides it and dissolves the preset" do
      dash = Dashboard.new()

      assert {:ok, dash} = Dashboard.toggle_box(dash, :plan, 200)
      refute Dashboard.visible?(dash, :plan)
      assert dash.preset == nil
    end

    test "toggling a hidden box back on restores it" do
      dash = Dashboard.new()
      {:ok, dash} = Dashboard.toggle_box(dash, :diff, 200)
      {:ok, dash} = Dashboard.toggle_box(dash, :diff, 200)

      assert Dashboard.visible?(dash, :diff)
    end

    test "turning capabilities on below its minimum refuses with the minimum" do
      dash = Dashboard.new()
      {:ok, dash} = Dashboard.toggle_box(dash, :capabilities, 100)

      assert {:error, 62} = Dashboard.toggle_box(dash, :capabilities, 61)
      refute Dashboard.visible?(dash, :capabilities)
    end

    test "capabilities toggles on exactly at its minimum" do
      dash = Dashboard.new()
      {:ok, dash} = Dashboard.toggle_box(dash, :capabilities, 100)

      assert {:ok, dash} = Dashboard.toggle_box(dash, :capabilities, 62)
      assert Dashboard.visible?(dash, :capabilities)
    end

    test "boxes without a minimum toggle freely at any width" do
      dash = Dashboard.new()
      {:ok, dash} = Dashboard.toggle_box(dash, :status, 100)

      assert {:ok, dash} = Dashboard.toggle_box(dash, :status, 20)
      assert Dashboard.visible?(dash, :status)
    end
  end

  describe "box_for_key/1" do
    test "digits 1-6 map to the strip-order boxes" do
      assert Dashboard.box_for_key("1") == :engine
      assert Dashboard.box_for_key("2") == :capabilities
      assert Dashboard.box_for_key("3") == :journal
      assert Dashboard.box_for_key("4") == :plan
      assert Dashboard.box_for_key("5") == :diff
      assert Dashboard.box_for_key("6") == :status
    end

    test "0 and 7+ are inert" do
      assert Dashboard.box_for_key("0") == nil
      assert Dashboard.box_for_key("7") == nil
      assert Dashboard.box_for_key("9") == nil
    end
  end

  describe "cycle/2 (btop preset cycling)" do
    test "p advances 0 → 1 → 2 and wraps" do
      dash = Dashboard.new()

      assert %{preset: 1} = dash = Dashboard.cycle(dash, :next)
      assert %{preset: 2} = dash = Dashboard.cycle(dash, :next)
      assert %{preset: 0} = Dashboard.cycle(dash, :next)
    end

    test "P goes backwards and wraps" do
      dash = Dashboard.new()

      assert %{preset: 2} = Dashboard.cycle(dash, :prev)
      assert %{preset: 1} = Dashboard.cycle(Dashboard.cycle(dash, :prev), :prev)
    end

    test "presets carry their documented membership" do
      assert Dashboard.presets()[0] == ~w(engine capabilities journal plan diff status)a
      assert Dashboard.presets()[1] == ~w(engine journal plan diff)a
      assert Dashboard.presets()[2] == ~w(engine journal)a
    end

    test "each preset's visible set matches its membership" do
      for id <- 0..2 do
        boxes = Dashboard.presets()[id]
        dash = Enum.reduce(1..id//1, Dashboard.new(), fn _, d -> Dashboard.cycle(d, :next) end)

        assert dash.preset == id

        assert MapSet.new(boxes) ==
                 MapSet.new(Enum.filter(Dashboard.boxes(), &Dashboard.visible?(dash, &1)))
      end
    end

    test "a dissolved tracker seeds p from before the list (next p = preset 0)" do
      {:ok, dash} = Dashboard.toggle_box(Dashboard.new(), :plan, 200)
      assert dash.preset == nil

      assert %{preset: 0} = Dashboard.cycle(dash, :next)
    end
  end

  describe "layout/2" do
    @width_mosaic 175
    @width_stack 80

    test "preset 0 at mosaic width lays out the slot mosaic" do
      boxes = Dashboard.layout(Dashboard.new(), {@width_mosaic, 83})
      # Row-major: the engine|journal row, the plan|diff row, then the
      # two full-width bands.
      laid_out = Enum.map(boxes, fn {box, _rect} -> box end)

      assert laid_out == ~w(engine journal plan diff capabilities status)a

      {_box, {_x, y, _w, _h}} = Enum.find(boxes, fn {box, _} -> box == :engine end)
      {_box, {_x, y_caps, _w, _h}} = Enum.find(boxes, fn {box, _} -> box == :capabilities end)
      assert y_caps > y
    end

    test "preset 0 below the mosaic width stacks the visible boxes full width" do
      boxes = Dashboard.layout(Dashboard.new(), {@width_stack, 24})
      rects = Enum.map(boxes, fn {_box, {_x, _y, w, _h}} -> w end)

      assert Enum.map(boxes, fn {box, _} -> box end) ==
               ~w(engine journal capabilities plan diff status)a

      assert Enum.all?(rects, &(&1 == @width_stack))
    end

    test "preset 1 audits plan+diff over an engine+journal band" do
      dash = Dashboard.new() |> Dashboard.cycle(:next)
      boxes = Dashboard.layout(dash, {@width_mosaic, 83})

      assert Enum.map(boxes, fn {box, _} -> box end) == ~w(plan diff engine journal)a

      {_box, {_x, _y, _w, h_plan}} = Enum.find(boxes, fn {box, _} -> box == :plan end)
      {_box, {_x, _y, _w, h_engine}} = Enum.find(boxes, fn {box, _} -> box == :engine end)

      assert h_plan > h_engine
    end

    test "preset 2 is engine+journal only" do
      dash = Dashboard.new() |> Dashboard.cycle(:next) |> Dashboard.cycle(:next)
      boxes = Dashboard.layout(dash, {@width_mosaic, 83})

      assert Enum.map(boxes, fn {box, _} -> box end) == ~w(engine journal)a
    end

    test "a dissolved set tiles its visible boxes in the dashboard shape" do
      {:ok, dash} = Dashboard.toggle_box(Dashboard.new(), :plan, @width_mosaic)
      {:ok, dash} = Dashboard.toggle_box(dash, :status, @width_mosaic)

      boxes = Dashboard.layout(dash, {@width_mosaic, 83})

      # Row-major over the slot rows with plan and status dropped: the
      # engine|journal row, the diff slot (its pair hidden), the caps band.
      assert Enum.map(boxes, fn {box, _} -> box end) == ~w(engine journal diff capabilities)a
    end

    test "boxes split their row: the pair takes half width each, a band takes it all" do
      boxes = Dashboard.layout(Dashboard.new(), {@width_mosaic, 83})

      {_box, {x_engine, _y, w_engine, _h}} = Enum.find(boxes, fn {box, _} -> box == :engine end)
      {_box, {x_journal, _y, w_journal, _h}} = Enum.find(boxes, fn {box, _} -> box == :journal end)
      {_box, {x_caps, _y, w_caps, _h}} = Enum.find(boxes, fn {box, _} -> box == :capabilities end)

      assert x_engine == 0
      assert x_journal == w_engine
      assert w_engine + w_journal == @width_mosaic
      assert {x_caps, w_caps} == {0, @width_mosaic}
    end

    test "an empty visible set tiles to nothing" do
      dash =
        Dashboard.new()
        |> then(fn d -> Enum.reduce(Dashboard.boxes(), d, fn box, d -> elem(Dashboard.toggle_box(d, box, 240), 1) end) end)

      assert Dashboard.layout(dash, {@width_mosaic, 83}) == []
    end
  end

  describe "islands/1 (the strip's single spelling)" do
    test "visible boxes glow, hidden boxes render dimmed bracket islands" do
      {:ok, dash} = Dashboard.toggle_box(Dashboard.new(), :plan, 200)
      islands = Dashboard.islands(dash)

      engine = Enum.find(islands, &(&1.key == "1"))
      assert engine.segs == [keycap: "¹", accent: "engine"]

      plan = Enum.find(islands, &(&1.key == "4"))
      assert plan.segs == [inactive: "[4] plan"]

      keys = Enum.map(islands, & &1.key)
      assert keys == ~w(1 2 3 4 5 6 p P)
    end

    test "the p/P islands are always present" do
      islands = Dashboard.islands(Dashboard.new())

      assert Enum.find(islands, &(&1.key == "p" and &1.segs == [keycap: "p", text: " next"]))
      assert Enum.find(islands, &(&1.key == "P" and &1.segs == [keycap: "P", text: " prev"]))
    end
  end

  describe "expansion (§1.6: in-place box deep views, never a screen)" do
    test "new/0 starts with nothing expanded" do
      assert Dashboard.expansion(Dashboard.new()) == nil
    end

    test "expand/2 marks the box; contract/1 re-tiles; the shell maps enter/Esc onto it" do
      for box <- ~w(capabilities plan diff)a do
        {:ok, expanded} = Dashboard.expand(Dashboard.new(), box)
        assert Dashboard.expansion(expanded) == box

        contract = Dashboard.contract(expanded)
        assert Dashboard.expansion(contract) == nil
        assert contract.preset == 0
      end
    end

    test "expand/2 refuses a hidden box (§1.6: no view of an absent box)" do
      {:ok, dash} = Dashboard.toggle_box(Dashboard.new(), :capabilities, 200)

      assert {:error, :hidden} = Dashboard.expand(dash, :capabilities)
      assert Dashboard.expansion(dash) == nil
    end

    test "zoomable?/1 covers exactly the drillable tree box and the read boxes" do
      assert Dashboard.zoomable?(:capabilities)
      assert Dashboard.zoomable?(:plan)
      assert Dashboard.zoomable?(:diff)

      refute Dashboard.zoomable?(:engine)
      refute Dashboard.zoomable?(:journal)
      refute Dashboard.zoomable?(:status)
    end

    test "a preset change dissolves the expansion (the same dissolve rule)" do
      {:ok, expanded} = Dashboard.expand(Dashboard.new(), :plan)
      assert Dashboard.expansion(Dashboard.cycle(expanded, :next)) == nil
      assert Dashboard.expansion(Dashboard.cycle(expanded, :prev)) == nil
    end

    test "toggling the expanded box off dissolves the expansion" do
      {:ok, expanded} = Dashboard.expand(Dashboard.new(), :diff)
      {:ok, dash} = Dashboard.toggle_box(expanded, :diff, 200)

      assert Dashboard.expansion(dash) == nil
    end

    test "resize clears the preset tracking but the deep view rides (sticky, like btop)" do
      {:ok, expanded} = Dashboard.expand(Dashboard.new(), :plan)

      dash = Dashboard.clear_tracking(expanded)
      assert dash.preset == nil
      assert Dashboard.expansion(dash) == :plan
      # The visible set survives a resize (only tracking dissolves).
      assert MapSet.equal?(dash.visible, Dashboard.new().visible)
    end

    test "an expanded plan box takes over the whole dashboard rect" do
      {:ok, expanded} = Dashboard.expand(Dashboard.new(), :plan)
      layout = Dashboard.layout(expanded, {175, 83})

      assert layout == [{:plan, {0, 0, 175, 83}}]
    end

    test "an expanded diff box takes over the whole dashboard rect at any width" do
      {:ok, expanded} = Dashboard.expand(Dashboard.new(), :diff)
      assert Dashboard.layout(expanded, {80, 24}) == [{:diff, {0, 0, 80, 24}}]
    end

    test "an expanded capabilities box grows its own cell in place (neighbors untouched)" do
      # 140x45: the caps slot is 6 rows, the drill wants 14, and the
      # dashboard bottom allows 11 — so the growth is visible (6 -> 11).
      {:ok, expanded} = Dashboard.expand(Dashboard.new(), :capabilities)
      layout = Dashboard.layout(expanded, {140, 45})
      plain = Dashboard.layout(Dashboard.new(), {140, 45})

      # The drill is the box's own mosaic cell growing over its
      # neighbors: same slot (x/y/width), height grows toward the 14-row
      # drill cap, bounded by the dashboard edge — position never
      # changes, no global re-tile (btop proc-expand semantics).
      caps = Enum.find(layout, fn {box, _} -> box == :capabilities end)
      plain_caps = Enum.find(plain, fn {box, _} -> box == :capabilities end)
      {_, {_x, _y, _w, _h} = plain_rect} = plain_caps
      assert caps == {:capabilities, put_elem(plain_rect, 3, min(14, 45 - elem(plain_rect, 1)))}

      # Every other box keeps its exact position and size.
      assert Enum.reject(layout, &match?({:capabilities, _}, &1)) ==
               Enum.reject(plain, &match?({:capabilities, _}, &1))

      # The expanded cell is drawn last — z-order puts it on top.
      assert layout |> List.last() |> elem(0) == :capabilities
    end

    test "a narrow dashboard grows the drill stack the same way" do
      {:ok, expanded} = Dashboard.expand(Dashboard.new(), :capabilities)
      layout = Dashboard.layout(expanded, {100, 30})

      assert Enum.find(layout, fn {box, {_x, _y, _w, h}} -> box == :capabilities and h == 14 end)
      assert length(layout) == 6
    end
  end
end
