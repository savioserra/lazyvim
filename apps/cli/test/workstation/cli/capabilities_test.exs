defmodule Workstation.CLI.CapabilitiesTest do
  # Feeds hand-built wire fragments with the REAL wire shapes (the same
  # shapes apps/daemon/lib/workstation/daemon/read.ex emits over the baked
  # report): the status wire carries the per-capability accounting rows;
  # the plan wire carries the declared surface and the probed target
  # states. Deterministic replay, no engine involved.
  use ExUnit.Case, async: true

  alias Workstation.CLI.Capabilities

  defp status_wire do
    %{
      "counts" => %{
        "capabilities" => 3,
        "claimTargets" => 1,
        "fileTargets" => 4,
        "fragments" => 0,
        "retire" => 1
      },
      "capabilityOrder" => ["helix", "nvim", "tmux"],
      "capabilities" => [
        %{
          "id" => "helix",
          "foundation" => "editor",
          "fileTargets" => [".config/helix/config.toml"],
          "claimTargets" => [],
          "fragments" => [],
          "retire" => [".config/helix/retired.conf"]
        },
        %{
          "id" => "nvim",
          "foundation" => "editor",
          "fileTargets" => [".config/nvim/init.lua", ".config/nvim/lua/plugins.lua"],
          "claimTargets" => [".config/nvim"],
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
    }
  end

  defp plan_wire do
    %{
      "generation" => String.duplicate("a", 64),
      "declared" => %{
        "fileTargets" => [
          ".config/helix/config.toml",
          ".config/nvim/init.lua",
          ".config/nvim/lua/plugins.lua",
          ".config/tmux/tmux.conf"
        ],
        "claimTargets" => [".config/nvim"],
        "retire" => [".config/helix/retired.conf"],
        "fragmentOrder" => []
      },
      "target_states" => %{
        ".config/nvim/init.lua" => "absent",
        ".config/nvim" => "absent"
      }
    }
  end

  defp envelope, do: Capabilities.group(%{"status" => status_wire(), "plan" => plan_wire()})

  defp find_domain(envelope, name), do: Enum.find(envelope["domains"], &(&1["name"] == name))

  defp find_capability(domain, name),
    do: Enum.find(domain["capabilities"], &(&1["name"] == name))

  test "group: envelope header counts" do
    env = envelope()

    assert env["schema"] == "workstation.capabilities.v1"
    assert env["generation"] == String.duplicate("a", 64)
  end

  test "group: domains keyed by report foundation, lifecycle order" do
    env = envelope()

    assert Enum.map(env["domains"], & &1["name"]) == ["editor", "terminal"]

    editor = find_domain(env, "editor")
    assert editor["foundation"] == "foundation/editor"
    assert Enum.map(editor["capabilities"], & &1["name"]) == ["helix", "nvim"]
    assert editor["targets"] == 2
    # helix: 1 file + 1 retire; nvim: 2 files + 1 claim.
    assert editor["files"] == 5
    # Nothing queues — the read verbs declare, the switch drivers mutate.
    assert editor["planned"] == 0

    terminal = find_domain(env, "terminal")
    assert Enum.map(terminal["capabilities"], & &1["name"]) == ["tmux"]
    assert terminal["files"] == 1
    assert terminal["planned"] == 0
  end

  test "group: target leaves carry their declared operation" do
    env = envelope()
    nvim = env |> find_domain("editor") |> find_capability("nvim")

    assert nvim["files"] == 3
    assert nvim["planned"] == 0

    init = Enum.find(nvim["entries"], &(&1["target"] == ".config/nvim/init.lua"))
    assert init["operation"] == "file"
    claim = Enum.find(nvim["entries"], &(&1["target"] == ".config/nvim"))
    assert claim["operation"] == "tree"

    helix = env |> find_domain("editor") |> find_capability("helix")
    retired = Enum.find(helix["entries"], &(&1["target"] == ".config/helix/retired.conf"))
    assert retired["operation"] == "retire"
  end

  test "group: every declared target appears exactly once across domains" do
    env = envelope()

    targets =
      Enum.flat_map(env["domains"], fn domain ->
        Enum.flat_map(domain["capabilities"], fn capability ->
          Enum.map(capability["entries"], & &1["target"])
        end)
      end)

    assert Enum.sort(targets) ==
             Enum.sort([
               ".config/helix/config.toml",
               ".config/helix/retired.conf",
               ".config/nvim/init.lua",
               ".config/nvim/lua/plugins.lua",
               ".config/nvim",
               ".config/tmux/tmux.conf"
             ])
  end

  test "group: the report attributes every target — no unattributed rows" do
    env = envelope()

    assert env["unattributed"] == []
    assert env["unattributed_files"] == 0
    assert env["unattributed_planned"] == 0
  end

  test "scope: domain scope keeps rollups, drops the rest" do
    env = envelope() |> Capabilities.scope(domain: "editor")

    assert Enum.map(env["domains"], & &1["name"]) == ["editor"]
    assert env["unattributed"] == []
    assert env["unattributed_files"] == 0
  end

  test "scope: capability scope drills to one capability and replans rollups" do
    env = envelope() |> Capabilities.scope(capability: "nvim")

    assert [%{"capabilities" => [%{"name" => "nvim"}], "name" => "editor"}] = env["domains"]
    editor = hd(env["domains"])
    assert editor["files"] == 3
    assert editor["targets"] == 1
    assert editor["planned"] == 0
  end

  test "scope: capability scope implies its domain, not other domains" do
    env = envelope() |> Capabilities.scope(capability: "tmux")

    assert Enum.map(env["domains"], & &1["name"]) == ["terminal"]
  end

  test "scope: unknown domain/capability yields an empty (but valid) envelope" do
    env = envelope() |> Capabilities.scope(domain: "nope")

    assert env["domains"] == []
    assert Capabilities.total_files(env) == 0
  end

  test "totals: sum declared targets across domains" do
    env = envelope()

    assert Capabilities.total_files(env) == 6
    assert Capabilities.total_planned(env) == 0
  end
end
