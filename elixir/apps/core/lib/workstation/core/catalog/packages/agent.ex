defmodule Workstation.Core.Catalog.Packages.Agent do
  @moduledoc """
  The `agent` workstation package's native contribution:
  the pi-subagents role definitions and the derived pi UI theme files.

  Why these four files and nothing else: the role definitions carry memory
  frontmatter intrinsic to pi-subagents (they shadow the bundled builtins
  wholesale), while pi's own settings.json — where the user picks
  "workstation-light/workstation-dark" — stays pi-owned, so the settings
  mutation remains factory `setup` Lua and never becomes managed state. The
  theme JSONs are templates rendered against the theme capability's
  chezmoidata envelope, hence the `theme` requirement alongside `node`.
  """

  alias Workstation.Core.Catalog.Packages

  @spec spec() :: map()
  def spec do
    %{
      id: "agent",
      requires: ["node", "theme"],
      supported_hosts: nil,
      contributes: [
        Packages.chezmoi(
          target: ".pi/agent/agents/worker.md",
          kind: :file,
          asset: "files/.pi/agent/agents/worker.md"
        ),
        Packages.chezmoi(
          target: ".pi/agent/agents/reviewer.md",
          kind: :file,
          asset: "files/.pi/agent/agents/reviewer.md"
        ),
        Packages.chezmoi(
          target: ".pi/agent/themes/workstation-dark.json",
          kind: :file,
          template: true,
          asset: "files/.pi/agent/themes/workstation-dark.json"
        ),
        Packages.chezmoi(
          target: ".pi/agent/themes/workstation-light.json",
          kind: :file,
          template: true,
          asset: "files/.pi/agent/themes/workstation-light.json"
        )
      ]
    }
  end
end
