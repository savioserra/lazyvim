local M = {}

-- Engine-owned retirement policy: the exact seventeen legacy tombstones of the
-- retired centralized deployment layouts. Feature owners declare their own
-- removal recipes; this list stays narrowly engine-scoped and must never grow
-- into a catch-all home payload package.

M.legacy_removals = {
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
	".local/share/workstation/versions.json",
}

---Full `.chezmoiremove` body for a generation: the engine policy entries plus
---explicitly declared and reconciled removals, deduplicated in order.
function M.remove_file(additions)
	local seen, lines, entries = {}, {}, {}
	for _, entry in ipairs(M.legacy_removals) do
		table.insert(entries, entry)
	end
	for _, entry in ipairs(additions or {}) do
		table.insert(entries, entry)
	end
	for _, entry in ipairs(entries) do
		assert(type(entry) == "string" and entry ~= "", "invalid removal entry")
		-- Reconciled owner removals may legitimately repeat a policy entry;
		-- the backend receives each tombstone exactly once.
		if not seen[entry] then
			seen[entry] = true
			table.insert(lines, entry)
		end
	end
	return table.concat(lines, "\n") .. "\n"
end

return M
