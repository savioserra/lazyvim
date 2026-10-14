defmodule Workstation.Core.Policy do
  @moduledoc """
  Engine-owned retirement policy: tombstones for the legacy centralized
  deployment layouts, enforced at source generation.

  The tombstone list is the exact seventeen legacy paths of the retired
  centralized deployment layouts. Feature owners declare their own removal
  recipes; this list stays narrowly engine-scoped and must never grow into a
  catch-all home payload package. Order is load-bearing: `.chezmoiremove`
  bytes are digested into the manifest, so reordering silently changes every
  generation id.
  """

  @legacy_removals [
    ".local/share/lazyvim",
    ".config/nvim/lua/capabilities",
    ".config/nvim/lua/languages/extras",
    ".pi/agent/skills/manage-lazyvim-workstation",
    ".pi/agent/skills/tmux-subagents",
    ".pi/agent/extensions/tmux-subagents",
    ".pi/agent/extensions/actor-client",
    ".pi/agent/extensions/hosted-pi-bridge",
    ".local/bin/workstation-tmux-subagents",
    ".local/bin/workstation-subagents",
    ".local/bin/workstation-subagents-clientctl",
    ".local/share/workstation/apps/tmux-subagents",
    ".config/workstation/subagents",
    ".config/systemd/user/workstation-subagents.service",
    "Library/LaunchAgents/com.workstation.subagents.plist",
    ".local/share/workstation/lua/workstation/packages",
    ".local/share/workstation/versions.json"
  ]

  @spec legacy_removals() :: [String.t()]
  def legacy_removals, do: @legacy_removals

  @doc """
  Full `.chezmoiremove` body for a generation: the engine policy entries plus
  explicitly declared and reconciled removals, deduplicated in order. A
  reconciled owner removal may legitimately repeat a policy entry, but the
  backend receives each tombstone exactly once.
  """
  @spec remove_file([String.t()]) :: String.t()
  def remove_file(additions) when is_list(additions) do
    entries = legacy_removals() ++ additions

    lines =
      for entry <- entries,
          valid_entry?(entry),
          uniq: true,
          do: entry

    Enum.join(lines, "\n") <> "\n"
  end

  defp valid_entry?(entry) when is_binary(entry) and entry != "", do: true

  defp valid_entry?(entry) do
    raise ArgumentError, "invalid removal entry: #{inspect(entry)}"
  end
end
