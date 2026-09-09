local paths = require("workstation.paths")
local state = require("workstation.state")

-- Attributable change sets for every provisioning recipe. The Git-style
-- patches describe GENERATED CHEZMOI SOURCE, never arbitrary HOME content:
-- they are an inspectable review surface for apply/removal, not mutation
-- authority and not a promise that backend effects are blindly reversible.

local M = {}

---Structured change-set records for one plan.
function M.changesets(plan)
	local records = {}
	for _, entry in ipairs(plan.entries) do
		table.insert(records, {
			owner = entry.owner,
			attribution = entry.attribution,
			provider = entry.provider,
			operation = entry.operation,
			target = entry.target,
			source = entry.source_name,
			type = entry.type,
			mode = entry.mode and string.format("%o", entry.mode),
			link = entry.link,
			shared = entry.shared or nil,
			source_fingerprint = entry.fingerprint,
		})
	end
	for _, removal in ipairs(plan.removals) do
		table.insert(records, {
			owner = removal.owner,
			provider = "chezmoi",
			operation = "remove",
			target = removal.target,
			type = "remove",
		})
	end
	return records
end

---Unified diff of generated source bytes in Git style. `previous` may be nil
---(new source entry) or a path inside the last applied generation.
local function patch(name, previous, next_path)
	local argv = { "diff", "-u", "--label", "a/" .. name, "--label", "b/" .. name, previous or "/dev/null", next_path }
	local result = vim.system(argv, { text = true }):wait()
	assert(result.code == 0 or result.code == 1, "diff failed: " .. (result.stderr or ""))
	local output = (result.stdout or ""):gsub("\n", "\n")
	if result.code == 0 then
		return ""
	end
	return output
end

---Compute the generated-source patch for one entry against the last applied
---generation. Non-text state keeps honest typed metadata instead of a fake
--- textual inverse.
function M.entry_patch(plan, entry)
	local applied = state.applied_record()
	if not applied or not applied.generation then
		return nil
	end
	local previous = paths.join(state.generations_root(), applied.generation, entry.source_name)
	if vim.uv.fs_stat(previous) == nil then
		previous = nil
	end
	if entry.bytes == nil then
		return nil
	end
	local temporary = paths.join(
		vim.env.TMPDIR or "/tmp",
		("workstation-patch-%d-%s"):format(vim.uv.os_getpid(), entry.source_name:gsub("/", "_"))
	)
	local file = assert(io.open(temporary, "wb"))
	assert(file:write(entry.bytes))
	file:close()
	local ok, result = pcall(patch, entry.source_name, previous, temporary)
	vim.fn.delete(temporary)
	if not ok then
		error(result)
	end
	return result ~= "" and result or nil
end

local function describe_target_state(entry)
	local stat = vim.uv.fs_lstat(paths.join(paths.home, entry.target))
	if not stat then
		return "absent"
	end
	return stat.type == "link" and ("link -> " .. vim.uv.fs_readlink(paths.join(paths.home, entry.target))) or stat.type
end

---Human-readable plan preview: attributable change sets, generated-source
---patches and actual-target preconditions, plus honest unsupported reversals.
function M.print_report(application, plan)
	print(("workstation plan (destination %s)"):format(application.context.paths.home))
	print(("  generation : %s"):format(plan.generation))
	print(("  entries    : %d  removals: %d"):format(#plan.entries, #plan.removals))
	for _, record in ipairs(M.changesets(plan)) do
		print(
			("  %s %s -> %s [%s] owner %s%s"):format(
				record.operation,
				record.source or "-",
				record.target,
				record.type
					.. (record.mode and (" mode " .. record.mode) or "")
					.. (record.link and (" link " .. record.link) or ""),
				table.concat(record.attribution or { record.owner }, ","),
				record.shared and " (shared)" or ""
			)
		)
	end
	if #plan.unsupported_reversals > 0 then
		print("  unsupported reversals (arbitrary whole-body modifiers; clean up explicitly):")
		for _, unsupported in ipairs(plan.unsupported_reversals) do
			print(("    %s (was owned by %s)"):format(unsupported.target, unsupported.owner))
		end
	end
	local applied = state.applied_record()
	if applied and applied.generation then
		print(("  last applied generation: %s"):format(applied.generation))
	end
	for _, entry in ipairs(plan.entries) do
		local entry_patch = M.entry_patch(plan, entry)
		if entry_patch then
			print(entry_patch)
		end
	end
	print("plan complete.")
end

return M
