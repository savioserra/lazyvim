local chezmoi_provider = require("workstation.provision.chezmoi")
local policy = require("workstation.provision.policy")
local shell_provider = require("workstation.provision.shell")
local state = require("workstation.state")

-- The source assembler: the composition root that interprets collected recipe
-- envelopes through the explicitly registered providers, composes domain
-- outputs before chezmoi source generation, detects ownership/path/attribute
-- conflicts and produces the deterministic plan shared by diff, apply and plan
-- previews. Core stays domain-neutral; this module owns the registry.

local M = {}

-- The complete registry of interpretable provider IDs. Unknown providers are
-- rejected here, never silently ignored.
M.registry = {
	[chezmoi_provider.id] = true,
	[shell_provider.id] = true,
	["nvim-profile"] = true,
}

local engine_state_target = ".local/state/workstation"

local function fail(message)
	error("workstation source plan: " .. message, 0)
end

local function is_within(target, ancestor)
	return target == ancestor or target:sub(1, #ancestor + 1) == ancestor .. "/"
end

local function assert_not_engine_state(target)
	assert(not is_within(target, engine_state_target), "recipe target overlaps engine-private state: " .. target)
end

local function collect(application)
	local collected = {}
	for _, specification in ipairs(application.graph.ordered) do
		for _, recipe in ipairs(specification.contributes or {}) do
			assert(M.registry[recipe.provider], specification.id .. " declares unknown provider " .. recipe.provider)
			table.insert(collected, {
				owner = specification.id,
				owner_root = application.packages_roots[specification.id],
				provider = recipe.provider,
				spec = recipe.spec,
			})
		end
	end
	return collected
end

local function compose_profile(application, collected)
	local intents = {}
	for _, record in ipairs(collected) do
		if record.provider == "nvim-profile" then
			table.insert(intents, { owner = record.owner, spec = record.spec })
		end
	end
	if #intents == 0 then
		return nil
	end
	local composer = require("packages.nvim.compose")
	local recipe, profile, owners = composer.compose(intents)
	return {
		owner = "nvim",
		owner_root = assert(application.packages_roots.nvim, "missing nvim package root"),
		provider = chezmoi_provider.id,
		spec = recipe.spec,
		attribution = owners,
	},
		profile
end

local function desired_fragments(collected)
	-- Group shell fragments per shared target in collection order; explicit
	-- fragment order keys plus graph-order tie-breaking keep output stable.
	local grouped, sequence = {}, 0
	for _, record in ipairs(collected) do
		if record.provider == shell_provider.id then
			shell_provider.validate_spec(record.spec)
			assert_not_engine_state(record.spec.target)
			local group = grouped[record.spec.target]
			if not group then
				group = { target = record.spec.target, fragments = {}, owners = {} }
				grouped[record.spec.target] = group
			end
			sequence = sequence + 1
			table.insert(group.fragments, {
				id = record.spec.fragment.id,
				marker = record.spec.fragment.marker,
				body = record.spec.fragment.body,
				order = record.spec.fragment.order,
				owner = record.owner,
				sequence = sequence,
			})
			table.insert(group.owners, record.owner)
		end
	end
	for _, group in pairs(grouped) do
		table.sort(group.fragments, function(left, right)
			if left.order ~= right.order then
				return left.order < right.order
			end
			return left.sequence < right.sequence
		end)
		local ids = {}
		for _, fragment in ipairs(group.fragments) do
			assert(not ids[fragment.id], "duplicate shell fragment id on " .. group.target .. ": " .. fragment.id)
			ids[fragment.id] = true
		end
	end
	return grouped
end

local function recorded_fragments(journal, target)
	local applied = journal and journal.fragments and journal.fragments[target]
	if not applied then
		return {}
	end
	local by_id = {}
	for _, fragment in ipairs(applied) do
		by_id[fragment.id] = fragment
	end
	return by_id
end

local function compose_shell_entries(collected, journal, ancestors)
	local entries, fragments_journal = {}, {}
	local grouped = desired_fragments(collected)
	-- Targets whose every recorded fragment disappeared still need one final
	-- recomposition so their exact known blocks are removed; leftover managed
	-- shell lines are not inert and stopping source management is not removal.
	for target, applied in pairs((journal and journal.fragments) or {}) do
		if not grouped[target] and #applied > 0 then
			grouped[target] = { target = target, fragments = {}, owners = {} }
		end
	end
	for target, group in pairs(grouped) do
		local recorded = recorded_fragments(journal, target)
		local desired, retired, kept = {}, {}, {}
		for _, fragment in ipairs(group.fragments) do
			table.insert(desired, fragment)
			kept[fragment.id] = true
		end
		for id, fragment in pairs(recorded) do
			if not kept[id] then
				table.insert(retired, fragment)
			end
		end
		table.sort(retired, function(left, right)
			return left.id < right.id
		end)
		local program = shell_provider.compose(target, desired, retired)
		local recipe = chezmoi_provider.recipe({
			target = target,
			kind = "modify",
			executable = true,
			content = program,
		})
		table.insert(entries, {
			owner = "shell",
			provider = chezmoi_provider.id,
			operation = "modify",
			target = target,
			source_name = chezmoi_provider.source_name(recipe.spec, ancestors),
			type = "modify",
			mode = chezmoi_provider.entry_mode(recipe.spec),
			bytes = program,
			shared = true,
			attribution = group.owners,
			fragments = desired,
		})
		if #desired > 0 then
			fragments_journal[target] = desired
		end
	end
	return entries, fragments_journal
end

local function build_entry(record, ancestors)
	chezmoi_provider.validate_spec(record.spec)
	assert_not_engine_state(record.spec.target)
	local spec = record.spec
	if spec.kind == "remove" then
		return {
			owner = record.owner,
			provider = chezmoi_provider.id,
			operation = "remove",
			target = spec.target,
			type = "remove",
			attribution = record.attribution or { record.owner },
		}
	end
	local bytes = spec.kind == "symlink" and spec.to or chezmoi_provider.source_bytes(spec, record.owner_root)
	local entry = {
		owner = record.owner,
		provider = chezmoi_provider.id,
		operation = spec.kind,
		target = spec.target,
		source_name = chezmoi_provider.source_name(spec, ancestors),
		type = spec.kind == "symlink" and "link" or spec.kind == "modify" and "modify" or spec.kind,
		mode = chezmoi_provider.entry_mode(spec),
		bytes = bytes,
		link = spec.kind == "symlink" and spec.to or nil,
		exact = spec.exact,
		template = spec.template,
		attribution = record.attribution or { record.owner },
		expected = chezmoi_provider.expected_state(spec, bytes),
		fragments = spec.fragments,
	}
	entry.fingerprint = state.sha256(vim.json.encode({
		target = entry.target,
		operation = entry.operation,
		type = entry.type,
		mode = entry.mode,
		bytes = bytes and state.sha256(bytes) or nil,
		link = entry.link,
		fragments = entry.fragments,
	}))
	return entry
end

local function directory_attributes(entry)
	return ("%s|%s|%s|%s"):format(
		entry.operation,
		entry.mode or "",
		entry.template and "tmpl" or "plain",
		tostring(entry.exact)
	)
end

local function detect_conflicts(entries, removals)
	local by_target, merged = {}, {}
	for _, entry in ipairs(entries) do
		local existing = by_target[entry.target]
		if existing then
			-- Only compatible shared-parent directory declarations may merge.
			assert(
				entry.operation == "directory" and existing.operation == "directory",
				"duplicate exclusive target "
					.. entry.target
					.. " owned by "
					.. table.concat(existing.attribution, ",")
					.. " and "
					.. table.concat(entry.attribution, ",")
			)
			assert(
				directory_attributes(existing) == directory_attributes(entry),
				"incompatible directory attributes for " .. entry.target
			)
			for _, owner in ipairs(entry.attribution) do
				if not vim.list_contains(existing.attribution, owner) then
					table.insert(existing.attribution, owner)
				end
			end
		else
			by_target[entry.target] = entry
			table.insert(merged, entry)
		end
	end
	for target, entry in pairs(by_target) do
		-- Ancestor type conflicts: no leaf may be declared under a non-directory.
		local prefix = target:match("^(.*/)[^/]+$")
		while prefix do
			local declared = by_target[prefix:sub(1, -2)]
			if declared and declared.operation ~= "directory" then
				fail(declared.target .. " is declared as " .. declared.operation .. " but also contains " .. target)
			end
			prefix = prefix:match("^(.*/)[^/]+$")
		end
		if entry.exact then
			-- exact_ containers require a single explicit owner and must not
			-- encompass other owners' targets or engine-private state.
			assert(#entry.attribution == 1, "exact directory " .. entry.target .. " requires exactly one owner")
			for other in pairs(by_target) do
				if other ~= entry.target and is_within(other, entry.target) then
					fail("exact directory " .. entry.target .. " encompasses target " .. other)
				end
			end
		end
	end
	for _, removal in ipairs(removals) do
		assert_not_engine_state(removal.target)
		for target, entry in pairs(by_target) do
			assert(
				not is_within(target, removal.target),
				"removal of " .. removal.target .. " overlaps owned target " .. target
			)
			assert(removal.target ~= target, "removal of " .. removal.target .. " overlaps owned target " .. target)
		end
	end
	-- Replace the plan's entry list with the merged one in place.
	for index in ipairs(entries) do
		entries[index] = nil
	end
	vim.list_extend(entries, merged)
	return by_target
end

---Reconcile disappeared exclusive recipes against the last applied journal.
---Exclusive leaves retire only with a matching recorded fingerprint; shared
---transformed files and containers are never deleted; arbitrary whole-body
---modifiers report an unsupported reversal instead of claiming removal.
local function reconcile(journal, by_target)
	local removals, unsupported = {}, {}
	local applied = journal and journal.targets or {}
	for target, record in pairs(applied) do
		if not by_target[target] then
			-- Deployment fingerprints record the on-disk type; ownership intent
			-- is the operation, so shared/transformed intent is decided there.
			if record.shared or record.operation == "modify" or record.operation == "directory" then
				if record.operation == "modify" and not record.shared then
					table.insert(unsupported, { target = target, owner = record.owner })
				end
				-- Shared or transformed targets are never deleted to retire a
				-- contribution; empty owned containers are left in place.
			else
				local fingerprint, failure = state.target_fingerprint(target)
				if failure then
					fail("cannot inspect owned target " .. target .. ": " .. failure)
				end
				assert(
					fingerprint ~= nil,
					"retiring " .. target .. " failed: it no longer exists; remove the stale journal entry manually"
				)
				assert(
					fingerprint.type == record.type
						and fingerprint.sha256 == record.sha256
						and fingerprint.link == record.link,
					("retiring %s failed: the target changed since the last apply (%s recorded, %s actual)"):format(
						target,
						record.type,
						fingerprint.type
					)
				)
				table.insert(removals, { target = target, owner = record.owner })
			end
		end
	end
	table.sort(removals, function(left, right)
		return left.target < right.target
	end)
	table.sort(unsupported, function(left, right)
		return left.target < right.target
	end)
	return removals, unsupported
end

---Deterministic source manifest: every generated path with type and mode,
---sorted by name so the generation id is stable.
local function build_manifest(plan)
	local manifest = {}
	local seen = {}
	local function include(name, entry)
		if not seen[name] then
			seen[name] = true
			table.insert(manifest, entry)
		end
	end
	for _, entry in ipairs(plan.entries) do
		include(entry.source_name, {
			name = entry.source_name,
			type = entry.type == "directory" and "directory" or "file",
			mode = entry.type == "directory" and (entry.mode or 493) or 420,
			sha256 = entry.bytes and state.sha256(entry.bytes) or nil,
		})
		local prefix = entry.source_name:match("^(.*)/[^/]+$")
		while prefix do
			include(prefix, { name = prefix, type = "directory", mode = 493 })
			prefix = prefix:match("^(.*)/[^/]+$")
		end
	end
	include(".chezmoiremove", {
		name = ".chezmoiremove",
		type = "file",
		mode = 420,
		sha256 = state.sha256(plan.remove_file),
	})
	table.sort(manifest, function(left, right)
		return left.name < right.name
	end)
	return manifest
end

---Build the validated source plan for one application state. Reads the
---journal, package assets and target metadata; performs no target mutation.
function M.plan(application)
	local collected = collect(application)
	local profile_record, profile = compose_profile(application, collected)
	if profile_record then
		table.insert(collected, profile_record)
	end
	local journal = state.applied_record()
	local ancestors = {}
	for _, record in ipairs(collected) do
		if record.provider == chezmoi_provider.id and record.spec.kind == "directory" then
			chezmoi_provider.validate_spec(record.spec)
			local existing = ancestors[record.spec.target]
			assert(
				existing == nil or (existing.exact == record.spec.exact and existing.private == record.spec.private),
				"incompatible directory attributes for " .. record.spec.target
			)
			ancestors[record.spec.target] = { exact = record.spec.exact, private = record.spec.private }
		end
	end
	local shell_entries, fragments_journal = compose_shell_entries(collected, journal, ancestors)
	local entries, removals = {}, {}
	for _, record in ipairs(collected) do
		if record.provider == chezmoi_provider.id then
			local entry = build_entry(record, ancestors)
			if entry.operation == "remove" then
				table.insert(removals, { target = entry.target, owner = entry.owner })
			else
				table.insert(entries, entry)
			end
		elseif record.provider ~= shell_provider.id and record.provider ~= "nvim-profile" then
			fail("unhandled provider " .. record.provider)
		end
	end
	vim.list_extend(entries, shell_entries)
	table.sort(entries, function(left, right)
		return left.source_name < right.source_name
	end)
	local by_target = detect_conflicts(entries, removals)
	local reconciled, unsupported = reconcile(journal, by_target)
	vim.list_extend(removals, reconciled)
	local remove_additions = {}
	for _, removal in ipairs(removals) do
		table.insert(remove_additions, removal.target)
	end
	local plan = {
		entries = entries,
		removals = removals,
		unsupported_reversals = unsupported,
		profile = profile,
		fragments_journal = fragments_journal,
		remove_file = policy.remove_file(remove_additions),
	}
	plan.manifest = build_manifest(plan)
	plan.generation = state.sha256(vim.json.encode(plan.manifest))
	if profile then
		application.context.nvim_profile = profile
	end
	return plan
end

return M
