defmodule Workstation.CLI.TUI.PureDrillTest do
  @moduledoc """
  The capabilities-browser drill sequence as a PURE state machine walk:
  the browser is driven key-by-key on a dumped grouped envelope and the
  resulting state is rendered directly — no live shell runtime, no async
  wire loads. This separates a view/state bug (fails here, always) from
  the async-wire race the live shell adds (fails only under
  shell_test.exs, and only when a settle misses a redraw).
  """

  use ExUnit.Case, async: true

  alias TermUI.{Frame, Style}
  alias Workstation.CLI.Capabilities
  alias Workstation.CLI.TUI.Shell.CapabilitiesBrowser

  test "browser drill reaches the nvim file row and the drilled pane renders it" do
    env = Capabilities.group(%{"status" => status_wire(), "plan" => plan_wire()})
    b0 = CapabilitiesBrowser.init(env)

    # Grain contract: the top level is domain rollups only — no file dump.
    assert Enum.all?(b0.rows, &(&1.kind == :domain))

    # enter expands the highlighted domain; its packages surface.
    b1 = CapabilitiesBrowser.update({:key, :enter}, b0)
    assert Enum.any?(b1.rows, &match?(%{kind: :package, path: "editor/nvim"}, &1))

    # down down lands the cursor on the nvim package row; enter drills it.
    b2 = CapabilitiesBrowser.update({:key, :down}, b1)
    b3 = CapabilitiesBrowser.update({:key, :down}, b2)
    assert Enum.at(b3.rows, b3.selected).path == "editor/nvim"

    b4 = CapabilitiesBrowser.update({:key, :enter}, b3)
    assert Enum.any?(b4.rows, fn
           %{kind: :file, path: path} -> path == "editor/nvim#.config/nvim/init.lua"
           _other -> false
         end)

    # The pure view on the drilled state renders the file leaf — and the
    # drill pane must be the active domain's SUBTREE (helix and nvim
    # package rows present), titled by the domain, not the slice after
    # the flat cursor.
    frame = CapabilitiesBrowser.view(b4, {100, 25}, styles())
    rendered = rendered_text(frame)
    assert rendered =~ ".config/nvim/init.lua"
    assert rendered =~ "helix — 1 files"
    assert rendered =~ "nvim — 1 files"
    # The drill pane is titled by the active domain as a border island.
    assert rendered =~ "editor"
  end

  defp rendered_text(frame) do
    1..frame.height
    |> Enum.map(&Frame.row_text(frame, &1))
    |> Enum.join("\n")
  end

  # Same resolved-role shape the shell's theme_styles/1 produces, with
  # :title as border-island span content exactly like shell.ex's
  # `Map.put(styles, :title, title)`; the pure test pins structure, so
  # plain unstyled roles are enough.
  defp styles do
    %{
      title: [{" capabilities ", Style.new(attrs: [:bold])}],
      accent: Style.new(attrs: [:bold]),
      ok: Style.new(),
      warn: Style.new(),
      err: Style.new(),
      shortcut: Style.new(attrs: [:bold]),
      inactive: Style.new(),
      chrome: Style.new(),
      selected: Style.new(),
      plain: Style.new()
    }
  end

  defp status_wire do
    %{
      "destination" => "/tmp/pure-drill-home",
      "platform" => "linux-test",
      "engine" => %{"name" => "workstation", "version" => "9.9.9-test", "mode" => "test"},
      "taxonomy" => %{
        "nvim" => "foundation/editor",
        "helix" => "foundation/editor",
        "tmux" => "foundation/terminal"
      },
      "packages" => [
        %{"id" => "nvim", "name" => "nvim", "targets" => [".config/nvim"]},
        %{"id" => "helix", "name" => "helix", "targets" => [".config/helix"]},
        %{"id" => "tmux", "name" => "tmux", "targets" => [".config/tmux"]}
      ],
      "graph_order" => ["tmux", "helix", "nvim"],
      "journal" => %{"generation" => 2, "revision" => 7, "applied_at" => "2026-02-13T10:00:00Z"}
    }
  end

  defp plan_wire do
    %{
      "generation" => "gen-3",
      "plan" => %{
        "entries" => [
          %{
            "source_name" => "dot_config/nvim/init.lua",
            "target" => ".config/nvim/init.lua",
            "attribution" => ["nvim"]
          },
          %{
            "source_name" => "dot_config/helix/config.toml",
            "target" => ".config/helix/config.toml",
            "attribution" => ["helix"]
          },
          %{
            "source_name" => "dot_config/tmux/tmux.conf",
            "target" => ".config/tmux/tmux.conf",
            "attribution" => ["tmux"]
          }
        ],
        "removals" => []
      },
      "patches" => [
        %{"target" => ".config/nvim/init.lua", "kind" => "write", "attribution" => ["nvim"]},
        %{"target" => ".config/tmux/tmux.conf", "kind" => "write", "attribution" => ["tmux"]}
      ]
    }
  end
end
