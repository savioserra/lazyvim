defmodule Workstation.CLI.RenderCapabilitiesTest do
  # Pure text-render tests for the grouped capabilities listing: hand-built
  # envelope (deterministic replay), assertions on the rollup-vs-drill-down
  # contract (no raw target dump at the top level).
  use ExUnit.Case, async: true

  alias Workstation.CLI.{Capabilities, Render}

  defp envelope do
    Capabilities.group(%{
      "status" => %{
        "capabilityOrder" => ["nvim", "tmux"],
        "capabilities" => [
          %{
            "id" => "nvim",
            "foundation" => "editor",
            "fileTargets" => [".config/nvim/init.lua"],
            "claimTargets" => [],
            "fragments" => [],
            "retire" => []
          },
          %{
            "id" => "tmux",
            "foundation" => "terminal",
            "fileTargets" => [".config/tmux/tmux.conf"],
            "claimTargets" => [],
            "fragments" => [],
            "retire" => []
          }
        ]
      },
      "plan" => %{
        "generation" => "9",
        "declared" => %{
          "fileTargets" => [".config/nvim/init.lua", ".config/tmux/tmux.conf"],
          "claimTargets" => [],
          "retire" => [],
          "fragmentOrder" => []
        },
        "target_states" => %{}
      }
    })
  end

  test "default listing: domain+capability rollups, no raw target dump" do
    text = Render.capabilities(envelope())

    assert text =~ "workstation capabilities  generation 9"
    assert text =~ "2 domains · 2 files · 0 would change"
    assert text =~ "editor       targets 1   files 1   planned 0"
    assert text =~ "nvim         files 1   planned 0"
    # The target leaf is hidden in the default rollup view...
    refute text =~ ".config/nvim/init.lua"
  end

  test "capability drill-down reveals the target leaves with the declared operation" do
    env = envelope() |> Capabilities.scope(capability: "nvim")
    text = Render.capabilities(env, capability: "nvim")

    assert text =~ "scope: capability nvim"
    assert text =~ ".config/nvim/init.lua"
    assert text =~ "file"
  end

  test "files flag flattens to the target-grained listing" do
    text = Render.capabilities(envelope(), files: true)

    assert text =~ ".config/nvim/init.lua"
    assert text =~ ".config/tmux/tmux.conf"
  end

  test "the target leaf shows its declared operation" do
    env = envelope() |> Capabilities.scope(capability: "nvim")
    text = Render.capabilities(env, capability: "nvim")

    leaf_line = Enum.find(String.split(text, "\n"), &String.contains?(&1, "init.lua"))
    assert leaf_line =~ "file"
    refute leaf_line =~ "would change"
  end

  test "json envelope via canonical JSON round-trips" do
    json = Workstation.Core.CanonicalJSON.encode(envelope())
    assert {:ok, decoded} = Workstation.Core.JSON.decode(json)

    assert decoded["schema"] == "workstation.capabilities.v1"
    assert decoded["generation"] == "9"
    assert [%{"name" => "editor"}, %{"name" => "terminal"}] = decoded["domains"]
  end

  test "empty report renders the empty-tree note, not an error" do
    empty =
      Capabilities.group(%{
        "status" => %{"capabilityOrder" => [], "capabilities" => []},
        "plan" => %{
          "generation" => "0",
          "declared" => %{"fileTargets" => [], "claimTargets" => [], "retire" => [], "fragmentOrder" => []},
          "target_states" => %{}
        }
      })

    text = Render.capabilities(empty)

    assert text =~ "no declared targets"
    assert text =~ "the report carries no declared surface"
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
          Map.update!(editor, "capabilities", fn [nvim] ->
            [
              Map.update!(nvim, "entries", fn [init] ->
                [%{init | "also" => ["tmux"]}]
              end)
            ]
          end)
          | rest
        ]
      end)
      |> Capabilities.scope(capability: "nvim")

    text = Render.capabilities(env, capability: "nvim")

    assert text =~ "also: tmux"
    # Exactly one init.lua row despite the extra attribution.
    assert text |> String.split("\n") |> Enum.count(&String.contains?(&1, "init.lua")) == 1
  end
end
