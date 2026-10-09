defmodule Workstation.Packages.PiSkills do
  @moduledoc """
  The `pi-skills` workstation package's native contribution:
  the private `.pi/agent` root plus one managed SKILL.md per registered
  skill (lazyvim, secrets).

  Skill discovery/verification against the installed pi package stays with
  the factory's Lua `verify` handler (it shells out to the managed node
  against the global npm root), so the native surface is only the deployed
  skill payloads.
  """

  @behaviour Workstation.Core.Catalog.Spec

  alias Workstation.Core.Catalog.Packages

  @skills ["lazyvim", "secrets"]

  @spec spec() :: map()
  def spec do
    skill_files =
      Enum.map(@skills, fn skill ->
        Packages.chezmoi(
          target: ".pi/agent/skills/#{skill}/SKILL.md",
          kind: :file,
          asset: "files/.pi/agent/skills/#{skill}/SKILL.md"
        )
      end)

    %{
      foundation: "foundation/agent",
      id: "pi-skills",
      requires: ["agent"],
      supported_hosts: nil,
      contributes: [Packages.chezmoi(target: ".pi/agent", kind: :directory, private: true)] ++ skill_files
    }
  end
end
