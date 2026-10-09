defmodule Workstation.Packages.Herdr do
  @moduledoc """
  The `herdr` workstation package's native contribution:
  one managed launcher symlink to the pinned herdr binary.

  The single-file download is the factory's Lua `setup` handler; lifecycle
  commands never start, stop, attach or inspect a Herdr server, pane or
  session, and verification stays static (`--version` prefix) for the same
  reason.

  Consumer-owned theme derivation: herdr reads the terminal layer directly
  (`name = "terminal"`, `auto_switch = true`) in its own live config — the
  theme contract carries no consumer records, so this choice lives here,
  with the only package that owns it.
  """

  @behaviour Workstation.Core.Catalog.Spec

  alias Workstation.Core.Catalog.Packages

  @spec spec() :: map()
  def spec do
    %{
      foundation: "foundation/agent",
      id: "herdr",
      requires: ["foundation"],
      supported_hosts: nil,
      contributes: [
        Packages.chezmoi(target: ".local/bin/herdr", kind: :symlink, to: "../opt/herdr/bin/herdr")
      ]
    }
  end
end
