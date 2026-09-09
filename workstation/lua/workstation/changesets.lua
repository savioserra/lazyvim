local paths = require("workstation.paths")
local state = require("workstation.state")

-- Attributable change sets for every provisioning recipe. The Git-style
-- patches describe GENERATED CHEZMOI SOURCE, never arbitrary HOME content:
-- they are an inspectable review surface for apply/removal, not mutation
-- authority and not a promise that backend effects are blindly reversible.
-- Patches bind to a prior baseline that is verified against the journal's
-- recorded manifest before anything is diffed.

local M = {}

local function assert_generation(id)
	assert(state.valid_generation_id(id), "journal records an invalid generation identifier")
end

---Verified prior baseline: the journal's recorded manifest is rechecked
---against the stored generation directory before any patch is derived from it.
---@return table? baseline { generation, directory, manifest, source_index }
local function verified_baseline()
	local applied = state.applied_record()
	if type(applied) ~= "table" or not applied.generation then
		return nil
	end
	assert_generation(applied.generation)
	assert(type(applied.manifest) == "table", "journal manifest is missing; rebuild the plan")
	assert(type(applied.source_index) == "table", "journal source index is missing; rebuild the plan")
	local directory = state.generation_directory(applied.generation)
	local provisioner = require("workstation.provisioner")
	assert(vim.uv.fs_stat(directory) ~= nil, "recorded generation directory is missing: " .. directory)
	assert(
		pcall(provisioner.verify_generation, directory, applied.manifest),
		"recorded generation no longer matches its journaled manifest: " .. directory
	)
	return {
		generation = applied.generation,
		directory = directory,
		manifest = applied.manifest,
		source_index = applied.source_index,
	}
end

---Structured change-set records for one plan: active entries, then retired
---source entries that the plan no longer contains.
function M.changesets(plan, baseline)
	baseline = baseline or verified_baseline()
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
	if baseline then
		local present = {}
		for _, entry in ipairs(plan.entries) do
			present[entry.source_name] = true
		end
		for _, manifest_entry in ipairs(baseline.manifest) do
			local name = manifest_entry.name
			if manifest_entry.type == "file" and not present[name] then
				local indexed = baseline.source_index[name] or {}
				table.insert(records, {
					owner = indexed.owner or "unknown",
					attribution = indexed.attribution,
					provider = "chezmoi",
					operation = "retire",
					target = indexed.target or name,
					source = name,
					type = indexed.type or "file",
					mode = indexed.mode and string.format("%o", indexed.mode),
					link = indexed.link,
				})
			end
		end
	end
	return records
end

---Unified diff of generated source bytes in Git style. `previous` may be nil
---(new source entry) or a path inside the verified baseline generation.
local function patch(name, previous, next_path)
	local argv = {
		"diff",
		"-u",
		"--label",
		"a/" .. name,
		"--label",
		"b/" .. name,
		previous or "/dev/null",
		next_path or "/dev/null",
	}
	local result = vim.system(argv, { text = true }):wait()
	assert(result.code == 0 or result.code == 1, "diff failed: " .. (result.stderr or ""))
	if result.code == 0 then
		return ""
	end
	return result.stdout or ""
end

local next_temporary = nil
local function stage_next(entry)
	if entry.bytes == nil then
		return nil
	end
	next_temporary = next_temporary
		or paths.join(vim.env.TMPDIR or "/tmp", ("workstation-patch-%d"):format(vim.uv.os_getpid()))
	local path = next_temporary .. "-" .. (entry.source_name:gsub("[^%w%-_%.]", "_"))
	local file = assert(io.open(path, "wb"))
	assert(file:write(entry.bytes))
	file:close()
	return path
end

local function clear_staged()
	if next_temporary then
		for name in vim.fs.dir(vim.fs.dirname(next_temporary)) do
			if vim.startswith(name, vim.fs.basename(next_temporary) .. "-") then
				vim.fn.delete(paths.join(vim.fs.dirname(next_temporary), name))
			end
		end
	end
end

---Compute every generated-source patch for a plan: additions on first plans,
---changes against the verified baseline, and deletions for retired entries.
---Non-text state keeps typed metadata instead of a fabricated text inverse.
---@return table[] patches { kind = "add"|"change"|"delete", source, owner, target, diff? }
function M.plan_patches(plan, baseline)
	baseline = baseline or verified_baseline()
	local patches = {}
	local function add(kind, entry, previous_path)
		local staged = stage_next(entry)
		local diff = staged and patch(entry.source_name, previous_path, staged) or ""
		if diff ~= "" or kind == "delete" then
			table.insert(patches, {
				kind = kind,
				source = entry.source_name,
				owner = entry.owner,
				attribution = entry.attribution,
				target = entry.target,
				type = entry.type,
				mode = entry.mode and string.format("%o", entry.mode),
				link = entry.link,
				diff = diff ~= "" and diff or nil,
			})
		end
	end
	for _, entry in ipairs(plan.entries) do
		local previous_path = baseline and paths.join(baseline.directory, entry.source_name)
		if baseline and vim.uv.fs_stat(previous_path) == nil then
			previous_path = nil
		end
		if entry.bytes == nil then
			-- Typed metadata only: directories carry mode, symlinks carry the
			-- link destination; neither is honestly representable as text.
			if not baseline or not baseline.source_index[entry.source_name] then
				table.insert(patches, {
					kind = "add",
					source = entry.source_name,
					owner = entry.owner,
					attribution = entry.attribution,
					target = entry.target,
					type = entry.type,
					mode = entry.mode and string.format("%o", entry.mode),
					link = entry.link,
				})
			end
		else
			if baseline and baseline.source_index[entry.source_name] then
				add("change", entry, previous_path)
			else
				add("add", entry, nil)
			end
		end
	end
	if baseline then
		local present = {}
		for _, entry in ipairs(plan.entries) do
			present[entry.source_name] = true
		end
		for _, manifest_entry in ipairs(baseline.manifest) do
			local name = manifest_entry.name
			if manifest_entry.type == "file" and not present[name] then
				if name == ".chezmoiremove" then
					-- The generated tombstone file is engine metadata: its
					-- changes are previewed as one attributed aggregate change
					-- below, never as a retired recipe.
				else
					local indexed = baseline.source_index[name] or {}
					local diff = patch(name, paths.join(baseline.directory, name), nil)
					table.insert(patches, {
						kind = "delete",
						source = name,
						owner = indexed.owner or "unknown",
						attribution = indexed.attribution,
						target = indexed.target or name,
						type = indexed.type or "file",
						diff = diff ~= "" and diff or nil,
					})
				end
			end
		end
		-- Aggregate tombstone changes name their contributors as the engine
		-- policy plus every removal's owner, not a fabricated single owner.
		local previous_remove = paths.read(paths.join(baseline.directory, ".chezmoiremove"))
		if previous_remove ~= plan.remove_file then
			local staged = paths.join(vim.env.TMPDIR or "/tmp", ("workstation-remove-%d"):format(vim.uv.os_getpid()))
			local file = assert(io.open(staged, "wb"))
			assert(file:write(plan.remove_file))
			file:close()
			local diff = patch(".chezmoiremove", paths.join(baseline.directory, ".chezmoiremove"), staged)
			vim.fn.delete(staged)
			local owners = { "engine-policy" }
			for _, removal in ipairs(plan.removals) do
				if not vim.list_contains(owners, removal.owner) then
					table.insert(owners, removal.owner)
				end
			end
			table.insert(patches, {
				kind = "change",
				source = ".chezmoiremove",
				owner = "engine",
				attribution = owners,
				target = ".chezmoiremove (aggregate tombstones)",
				type = "file",
				diff = diff ~= "" and diff or nil,
			})
		end
	end
	clear_staged()
	return patches
end

local function describe_target_state(target)
	local path = state.join_home(target)
	local stat = vim.uv.fs_lstat(path)
	if not stat then
		return "absent"
	end
	if stat.type == "link" then
		return "link -> " .. vim.uv.fs_readlink(path)
	end
	return ("%s %o"):format(stat.type, bit.band(stat.mode, 4095))
end

---Human-readable plan preview: attributable change sets, complete
---add/change/delete generated-source patches, actual-target precondition
---status, and honest unsupported reversals. Never prints home-file bodies.
function M.print_report(application, plan)
	local baseline = verified_baseline()
	print(("workstation plan (destination %s)"):format(application.context.paths.home))
	print(("  generation : %s"):format(plan.generation))
	print(("  entries    : %d  removals: %d"):format(#plan.entries, #plan.removals))
	if baseline then
		print(("  baseline   : %s (verified against the journaled manifest)"):format(baseline.generation))
	else
		print("  baseline   : none (initial plan; every source entry is an addition)")
	end
	for _, record in ipairs(M.changesets(plan, baseline)) do
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
	for _, entry in ipairs(plan.entries) do
		print(("  target %-45s %s"):format(entry.target, describe_target_state(entry.target)))
	end
	for _, removal in ipairs(plan.removals) do
		print(("  target %-45s %s (removal)"):format(removal.target, describe_target_state(removal.target)))
	end
	for _, entry_patch in ipairs(M.plan_patches(plan, baseline)) do
		if entry_patch.diff then
			io.write(entry_patch.diff)
		else
			print(
				("# %s %s (%s, owner %s)%s"):format(
					entry_patch.kind,
					entry_patch.source,
					entry_patch.type
						.. (entry_patch.mode and (" mode " .. entry_patch.mode) or "")
						.. (entry_patch.link and (" link " .. entry_patch.link) or ""),
					table.concat(entry_patch.attribution or { entry_patch.owner }, ","),
					entry_patch.link and " link " .. entry_patch.link or ""
				)
			)
		end
	end
	print("plan complete.")
end

return M
