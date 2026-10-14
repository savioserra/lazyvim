defmodule Workstation.CLI.CapabilitiesTest do
  # Feeds hand-built wire fragments with the REAL wire shapes (the same
  # shapes apps/daemon/lib/workstation/daemon/read.ex emits): the status
  # wire carries a package -> foundation `taxonomy` map and the `journal`;
  # the plan wire carries `plan.entries` (with `attribution` owner lists)
  # and changeset `patches`. Deterministic replay, no engine involved.
  use ExUnit.Case, async: true

  alias Workstation.CLI.Capabilities

  defp status_wire do
    %{
      "generation" => 2,
      "taxonomy" => %{
        "nvim" => "foundation/editor",
        "helix" => "foundation/editor",
        "tmux" => "foundation/terminal"
      },
      "journal" => %{"generation" => "2", "revision" => 5, "at" => "2026-01-01T00:00:00Z"}
    }
  end

  defp plan_wire do
    %{
      "generation" => 4,
      "plan" => %{
        "entries" => [
          %{
            "owner" => "nvim",
            "attribution" => ["nvim", "theme"],
            "operation" => "write",
            "target" => ".config/nvim/init.lua",
            "source_name" => "init.lua",
            "type" => "file",
            "mode" => "0644"
          },
          %{
            "owner" => "nvim",
            "attribution" => ["nvim"],
            "operation" => "write",
            "target" => ".config/nvim/lua/plugins.lua",
            "source_name" => "plugins.lua",
            "type" => "file",
            "mode" => "0644"
          },
          %{
            "owner" => "helix",
            "attribution" => ["helix"],
            "operation" => "write",
            "target" => ".config/helix/config.toml",
            "source_name" => "config.toml",
            "type" => "file",
            "mode" => "0644"
          },
          # Two attributions with NO package owner of its own: files under
          # the primary package; the co-owner rides the row as "also".
          %{
            "owner" => "nvim",
            "attribution" => ["nvim", "tmux"],
            "operation" => "write",
            "target" => ".config/shared/init.lua",
            "source_name" => "shared.lua",
            "type" => "file",
            "mode" => "0644"
          },
          # tmux contributes a brand-new file: an entry WITH a matching add
          # patch, so the planned join has an entry row to land on.
          %{
            "owner" => "tmux",
            "attribution" => ["tmux"],
            "operation" => "write",
            "target" => ".config/tmux/tmux.conf",
            "source_name" => "tmux.conf",
            "type" => "file",
            "mode" => "0644"
          },
          # No attribution at all: the honest "unattributed" bucket.
          %{
            "owner" => "unknown",
            "operation" => "write",
            "target" => ".local/loose.txt",
            "source_name" => "loose.txt",
            "type" => "file",
            "mode" => "0644"
          }
        ]
      },
      "patches" => [
        %{
          "kind" => "change",
          "source" => "init.lua",
          "attribution" => ["nvim", "theme"],
          "target" => ".config/nvim/init.lua",
          "type" => "file",
          "mode" => "0644",
          "diff" => "--- a/init.lua\n+++ b/init.lua\n"
        },
        %{
          "kind" => "add",
          "source" => "tmux.conf",
          "attribution" => ["tmux"],
          "target" => ".config/tmux/tmux.conf",
          "type" => "file",
          "mode" => "0644"
        },
        # A retired-target deletion whose target is NOT in the plan entries:
        # joins as its own delete row under its attribution.
        %{
          "kind" => "delete",
          "source" => "retired.conf",
          "attribution" => ["helix"],
          "target" => ".config/helix/retired.conf",
          "type" => "file"
        },
        # An orphan non-delete patch (target absent from the plan entries):
        # neither crashes nor invents rows.
        %{
          "kind" => "add",
          "source" => "orphan.txt",
          "attribution" => nil,
          "target" => ".local/orphan.txt",
          "type" => "file"
        }
      ]
    }
  end

  defp envelope, do: Capabilities.group(%{"status" => status_wire(), "plan" => plan_wire()})

  defp find_domain(envelope, name), do: Enum.find(envelope["domains"], &(&1["name"] == name))

  defp find_package(domain, name),
    do: Enum.find(domain["packages"], &(&1["name"] == name))

  test "group: envelope header counts" do
    env = envelope()

    assert env["schema"] == "workstation.capabilities.v1"
    assert env["generation"] == 4
    assert env["applied_generation"] == "2"
  end

  test "group: domains keyed by taxonomy foundation, lifecycle order" do
    env = envelope()

    assert Enum.map(env["domains"], & &1["name"]) == ["editor", "terminal"]

    editor = find_domain(env, "editor")
    assert editor["foundation"] == "foundation/editor"
    assert Enum.map(editor["packages"], & &1["name"]) == ["helix", "nvim"]
    assert editor["targets"] == 2
    assert editor["files"] == 5
    # init.lua planned + the retired-target deletion.
    assert editor["planned"] == 2

    terminal = find_domain(env, "terminal")
    # tmux owns tmux.conf only; shared.lua rides under nvim as also.
    assert Enum.map(terminal["packages"], & &1["name"]) == ["tmux"]
    assert terminal["files"] == 1
    assert terminal["planned"] == 1
  end

  test "group: file leaves under their primary package with also-riders" do
    env = envelope()
    nvim = env |> find_domain("editor") |> find_package("nvim")

    assert nvim["files"] == 3
    assert nvim["planned"] == 1

    init = Enum.find(nvim["entries"], &(&1["target"] == ".config/nvim/init.lua"))
    assert init["planned"] == true
    shared = Enum.find(nvim["entries"], &(&1["target"] == ".config/shared/init.lua"))
    assert shared["planned"] == false
    # The co-owner attribution is visible in the JSON envelope.
    assert shared["also"] == ["tmux"]
  end

  test "group: every catalog file appears exactly once across domains" do
    env = envelope()

    targets =
      Enum.flat_map(env["domains"], fn domain ->
        Enum.flat_map(domain["packages"], fn package ->
          Enum.map(package["entries"], & &1["target"])
        end)
      end)

    assert Enum.sort(targets) ==
             Enum.sort([
               ".config/nvim/init.lua",
               ".config/nvim/lua/plugins.lua",
               ".config/helix/config.toml",
               ".config/helix/retired.conf",
               ".config/shared/init.lua",
               ".config/tmux/tmux.conf"
             ])
  end

  test "group: unattributed rows keep their own honest bucket" do
    env = envelope()

    assert [%{"target" => ".local/loose.txt", "planned" => false}] = env["unattributed"]
    assert env["unattributed_files"] == 1
    assert env["unattributed_planned"] == 0
  end

  test "scope: domain scope keeps rollups, drops the rest" do
    env = envelope() |> Capabilities.scope(domain: "editor")

    assert Enum.map(env["domains"], & &1["name"]) == ["editor"]
    assert env["unattributed"] == []
    assert env["unattributed_files"] == 0
  end

  test "scope: package scope drills to one package and replans rollups" do
    env = envelope() |> Capabilities.scope(package: "nvim")

    assert [%{"packages" => [%{"name" => "nvim"}], "name" => "editor"}] = env["domains"]
    editor = hd(env["domains"])
    assert editor["files"] == 3
    assert editor["targets"] == 1
    assert editor["planned"] == 1
  end

  test "scope: package scope implies its domain, not other domains" do
    env = envelope() |> Capabilities.scope(package: "tmux")

    assert Enum.map(env["domains"], & &1["name"]) == ["terminal"]
  end

  test "scope: unknown domain/package yields an empty (but valid) envelope" do
    env = envelope() |> Capabilities.scope(domain: "nope")

    assert env["domains"] == []
    assert Capabilities.total_files(env) == 0
  end

  test "totals: sum files and planned across domains" do
    env = envelope()

    assert Capabilities.total_files(env) == 7
    # init.lua (nvim), tmux.conf (tmux), retired.conf deletion.
    assert Capabilities.total_planned(env) == 3
  end
end
