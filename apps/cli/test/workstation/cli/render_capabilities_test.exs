defmodule Workstation.CLI.RenderCapabilitiesTest do
  # Pure text-render tests for the grouped capabilities listing: hand-built
  # envelope (deterministic replay), assertions on the rollup-vs-drill-down
  # contract (no raw file dump at the top level).
  use ExUnit.Case, async: true

  alias Workstation.CLI.{Capabilities, Render}

  defp envelope do
    Capabilities.group(%{
      "status" => %{
        "generation" => 7,
        "taxonomy" => %{"nvim" => "foundation/editor", "tmux" => "foundation/terminal"},
        "journal" => %{"generation" => "7"}
      },
      "plan" => %{
        "generation" => 9,
        "plan" => %{
          "entries" => [
            %{
              "owner" => "nvim",
              "attribution" => ["nvim"],
              "operation" => "write",
              "target" => ".config/nvim/init.lua",
              "source_name" => "init.lua",
              "type" => "file",
              "mode" => "0644"
            },
            %{
              "owner" => "tmux",
              "attribution" => ["tmux"],
              "operation" => "write",
              "target" => ".config/tmux/tmux.conf",
              "source_name" => "tmux.conf",
              "type" => "file",
              "mode" => "0644"
            }
          ]
        },
        "patches" => [
          %{
            "kind" => "change",
            "source" => "init.lua",
            "attribution" => ["nvim"],
            "target" => ".config/nvim/init.lua",
            "type" => "file",
            "mode" => "0644",
            "diff" => "--- a/init.lua\n+++ b/init.lua\n"
          }
        ]
      }
    })
  end

  test "default listing: domain+package rollups, no raw file dump" do
    text = Render.capabilities(envelope())

    assert text =~ "workstation capabilities  generation 9  applied 7"
    assert text =~ "2 domains · 2 files · 1 would change"
    assert text =~ "editor       targets 1   files 1   planned 1"
    assert text =~ "nvim         files 1   planned 1"
    # The file leaf is hidden in the default rollup view...
    refute text =~ ".config/nvim/init.lua"
  end

  test "package drill-down reveals the file leaves with would-change marks" do
    env = envelope() |> Capabilities.scope(package: "nvim")
    text = Render.capabilities(env, package: "nvim")

    assert text =~ "scope: package nvim"
    assert text =~ ".config/nvim/init.lua"
    assert text =~ "would change"
  end

  test "files flag flattens to the file-grained listing" do
    text = Render.capabilities(envelope(), files: true)

    assert text =~ ".config/nvim/init.lua"
    assert text =~ ".config/tmux/tmux.conf"
  end

  test "planned file shows operation and would-change, with its mode" do
    env = envelope() |> Capabilities.scope(package: "nvim")
    text = Render.capabilities(env, package: "nvim")

    planned_line = Enum.find(String.split(text, "\n"), &String.contains?(&1, "init.lua"))
    assert planned_line =~ "write"
    assert planned_line =~ "would change"
    assert planned_line =~ "0644"
  end

  test "json envelope via canonical JSON round-trips" do
    json = Workstation.Core.CanonicalJSON.encode(envelope())
    assert {:ok, decoded} = Workstation.Core.JSON.decode(json)

    assert decoded["schema"] == "workstation.capabilities.v1"
    assert decoded["generation"] == 9
    assert [%{"name" => "editor"}, %{"name" => "terminal"}] = decoded["domains"]
  end

  test "empty catalog renders the bootstrap hint, not an error" do
    empty =
      Capabilities.group(%{
        "status" => %{"generation" => 0, "taxonomy" => %{}, "journal" => :null},
        "plan" => %{"generation" => 0, "plan" => %{"entries" => []}, "patches" => []}
      })

    text = Render.capabilities(empty)

    assert text =~ "no catalog entries"
    assert text =~ "bootstrap"
  end

  test "domain scope hides the unattributed section" do
    env =
      envelope()
      |> Map.put("unattributed", [%{"target" => ".local/loose.txt", "planned" => false}])
      |> Capabilities.scope(domain: "editor")

    text = Render.capabilities(env, domain: "editor")

    refute text =~ "unattributed"
  end

  test "unattributed rows render in their own section" do
    env =
      envelope()
      |> Map.put("unattributed", [%{"target" => ".local/loose.txt", "planned" => false}])

    text = Render.capabilities(env)

    assert text =~ "unattributed files 1   planned 0"
    assert text =~ ".local/loose.txt"
  end

  test "also-riders render as a note, never extra rows" do
    env =
      envelope()
      |> Map.update!("domains", fn [editor | rest] ->
        [
          Map.update!(editor, "packages", fn [nvim] ->
            [
              Map.update!(nvim, "entries", fn [init] ->
                [%{init | "also" => ["tmux"]}]
              end)
            ]
          end)
          | rest
        ]
      end)
      |> Capabilities.scope(package: "nvim")

    text = Render.capabilities(env, package: "nvim")

    assert text =~ "also: tmux"
    # Exactly one init.lua row despite two attributions.
    assert text |> String.split("\n") |> Enum.count(&String.contains?(&1, "init.lua")) == 1
  end
end
