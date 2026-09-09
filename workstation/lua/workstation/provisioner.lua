local commands = require("workstation.commands")
local paths = require("workstation.paths")
local state = require("workstation.state")

-- The chezmoi provisioner: the ONLY sanctioned way the engine materializes
-- home state. Chezmoi is a subordinate file provisioner invoked with an
-- explicit immutable generated --source and --destination; it is never driven
-- by the user or by packages, and home effects are never patched directly.

-- LuaJIT exposes varargs unpack as the global `unpack`; Lua 5.2+ as table.unpack.
local varargs_unpack = table.unpack or unpack

local M = {}

local script = debug.getinfo(1, "S").source:gsub("^@", "")
local module_path = vim.fs.normalize(script)
-- provisioner.lua lives at <repo>/workstation/lua/workstation/provisioner.lua
local engine_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(module_path)))

---Walk up from the engine root to the git root; fall back to the engine's
---parent directory (repo layout: the engine clone hosts packages and docs).
---@return string
function M.repo_root()
	local dir = engine_root
	for _ = 1, 16 do
		if vim.uv.fs_stat(paths.join(dir, ".git")) then
			return dir
		end
		local parent = vim.fs.dirname(dir)
		if parent == dir then
			break
		end
		dir = parent
	end
	return vim.fs.dirname(engine_root)
end

local function chezmoi_executable()
	return paths.join(paths.local_dir, "opt", "chezmoi", "bin", "chezmoi")
end

function M.ensure_backend()
	local host = vim.uv.os_uname()
	local asset = host.sysname == "Linux" and host.machine == "x86_64" and "linux_x86_64"
		or host.sysname == "Darwin" and host.machine == "arm64" and "darwin_arm64"
	assert(asset, "unsupported backend platform: " .. host.sysname .. "/" .. host.machine)
	local versions = require("workstation.versions")
	require("workstation.provision").create(asset == "linux_x86_64" and "linux" or "darwin").archive({
		url = versions["chezmoi_" .. asset .. "_url"]:gsub("{V}", versions.chezmoi),
		sha256 = versions["chezmoi_" .. asset .. "_sha256"],
		format = "tar",
		inner_path = "chezmoi",
		dest = chezmoi_executable(),
	})
end

---Build the full chezmoi argv for an action against one exact immutable
---generation directory, never a mutable current pointer.
---@param action string chezmoi action, e.g. "apply" or "diff"
---@param opts { source: string, exclude?: string[], dry_run?: boolean, destination?: string }
---@return string[]
function M.argv(action, opts)
	assert(type(opts) == "table" and opts.source, "chezmoi argv requires an explicit source generation")
	local argv = {
		chezmoi_executable(),
		"--source",
		opts.source,
		"--destination",
		opts.destination or paths.home,
		action,
	}
	if opts.dry_run then
		table.insert(argv, "--dry-run")
	end
	for _, exclude in ipairs(opts.exclude or { "scripts" }) do
		table.insert(argv, "--exclude")
		table.insert(argv, exclude)
	end
	return argv
end

local function run_backend(action, generation, options)
	local argv = M.argv(action, { source = generation, destination = options.destination })
	commands.execute(argv[1], { select(2, varargs_unpack(argv)) })
end

---Write one staged generation entry. Every ancestor directory is a manifest
---entry of its own and is created with its explicit mode: implicit mkdir -p
---would inherit the caller umask and break byte/mode verification.
local function write_staged(root, entry)
	local path = paths.join(root, entry.name)
	local prefix = entry.name:match("^(.*)/[^/]+$")
	while prefix do
		local parent = paths.join(root, prefix)
		if vim.uv.fs_stat(parent) == nil then
			assert(vim.uv.fs_mkdir(parent, 493))
		end
		prefix = prefix:match("^(.*)/[^/]+$")
	end
	if entry.type == "directory" then
		if vim.uv.fs_stat(path) == nil then
			assert(vim.uv.fs_mkdir(path, entry.mode or 493))
		end
		assert(vim.uv.fs_chmod(path, entry.mode or 493))
		return
	end
	local file = assert(io.open(path, "wb"))
	assert(file:write(entry.bytes or ""))
	file:close()
	assert(vim.uv.fs_chmod(path, entry.mode or 420))
end

---Verify a generation directory byte-for-byte against its manifest. A
---hash-shaped pathname alone is never trusted.
local function verify_generation(root, manifest)
	local expected, expected_count = {}, 0
	for _, entry in ipairs(manifest) do
		assert(type(entry.name) == "string" and entry.name ~= "", "manifest entry has no name")
		assert(expected[entry.name] == nil, "duplicate manifest entry: " .. entry.name)
		expected[entry.name] = entry
		expected_count = expected_count + 1
	end
	local actual = {}
	local function visit(name)
		local path = paths.join(root, name)
		local stat = assert(vim.uv.fs_lstat(path), "generation entry is missing: " .. name)
		local record = { type = stat.type, mode = bit.band(stat.mode, 4095) }
		if stat.type == "file" then
			local file = assert(io.open(path, "rb"))
			local contents = file:read("*a")
			file:close()
			record.sha256 = state.sha256(contents)
		end
		actual[name] = record
		if stat.type == "directory" then
			for child in vim.fs.dir(path) do
				visit(name == "" and child or name .. "/" .. child)
			end
		end
	end
	for child in vim.fs.dir(root) do
		visit(child)
	end
	for name, entry in pairs(expected) do
		local record = actual[name]
		assert(record, "generation is missing entry: " .. name)
		assert(record.type == entry.type, "generation entry has the wrong type: " .. name)
		assert(record.mode == entry.mode, "generation entry has the wrong mode: " .. name)
		assert(entry.sha256 == nil or record.sha256 == entry.sha256, "generation entry has the wrong bytes: " .. name)
	end
	local total = 0
	for _ in pairs(actual) do
		total = total + 1
	end
	assert(total == expected_count, "generation contains unexpected entries")
	return true
end

---Publish the plan's immutable content-addressed source generation and return
---its exact path. Identical generations are deduplicated after re-verification.
local function publish(plan)
	local root = state.generations_root()
	local directory = paths.join(root, plan.generation)
	local stat = vim.uv.fs_stat(directory)
	if stat then
		local ok = pcall(verify_generation, directory, plan.manifest)
		if ok then
			return directory
		end
		-- A damaged cached generation is quarantined, never silently trusted
		-- or partially reused.
		local quarantine = ("%s.invalid-%d-%d"):format(directory, vim.uv.os_getpid(), os.time())
		assert(vim.uv.fs_rename(directory, quarantine), "cannot quarantine damaged generation: " .. directory)
	end
	local staged = paths.join(root, (".staging-%d-%d"):format(vim.uv.os_getpid(), os.time()))
	vim.fn.delete(staged, "rf")
	vim.fn.mkdir(staged, "p")
	assert(vim.uv.fs_chmod(staged, 448))
	local bytes = { [".chezmoiremove"] = plan.remove_file }
	for _, entry in ipairs(plan.entries) do
		bytes[entry.source_name] = entry.bytes
	end
	local ok, failure = pcall(function()
		-- The manifest is sorted by name, so parent directories are staged
		-- before their children regardless of the caller's umask.
		for _, entry in ipairs(plan.manifest) do
			write_staged(staged, {
				name = entry.name,
				type = entry.type,
				mode = entry.mode,
				bytes = bytes[entry.name],
			})
		end
		assert(verify_generation(staged, plan.manifest))
	end)
	if not ok then
		vim.fn.delete(staged, "rf")
		error(failure)
	end
	local published, err = vim.uv.fs_rename(staged, directory)
	if not published then
		vim.fn.delete(staged, "rf")
		error("cannot publish generation " .. plan.generation .. ": " .. tostring(err))
	end
	return directory
end

M.publish = publish

---Check actual target preconditions for every planned mutation: intervening
---home edits, first adoption of different unrecorded whole files, symlinked
---ancestors and removal safety. Conflicts stop before backend mutation.
local function check_preconditions(plan)
	local journal = state.applied_record()
	local pending = state.pending_records()
	local pending_generations = {}
	for _, record in ipairs(pending) do
		pending_generations[record.generation] = true
	end
	local function conflict(entry, message)
		error(
			("workstation apply conflict at %s (owner %s): %s"):format(
				entry.target,
				table.concat(entry.attribution, ","),
				message
			),
			0
		)
	end
	for _, entry in ipairs(plan.entries) do
		local path = paths.join(paths.home, entry.target)
		local stat = vim.uv.fs_lstat(path)
		-- Never write through a symlinked ancestor into unrelated state.
		local ancestor = entry.target:match("^(.*/)[^/]+$")
		while ancestor do
			local ancestor_stat = vim.uv.fs_lstat(paths.join(paths.home, ancestor:sub(1, -2)))
			assert(
				ancestor_stat == nil or ancestor_stat.type ~= "link",
				"refusing to write through symlinked ancestor " .. ancestor:sub(1, -2) .. " for " .. entry.target
			)
			ancestor = ancestor:match("^(.*/)[^/]+$")
		end
		if entry.operation == "directory" then
			if stat and stat.type ~= "directory" then
				conflict(entry, "target exists as " .. stat.type)
			end
		elseif not stat then
			-- absent targets are adoptable
		elseif entry.operation == "modify" then
			if stat.type ~= "file" then
				conflict(entry, "shared target exists as " .. stat.type)
			end
		else
			local recorded = journal and journal.targets and journal.targets[entry.target]
			if recorded then
				local fingerprint = state.target_fingerprint(entry.target)
				if
					fingerprint == nil
					or fingerprint.type ~= recorded.type
					or fingerprint.sha256 ~= recorded.sha256
					or fingerprint.link ~= recorded.link
				then
					conflict(entry, "target changed since the last successful apply")
				end
			elseif entry.expected then
				local fingerprint = state.target_fingerprint(entry.target)
				if
					fingerprint.type ~= entry.expected.type
					or fingerprint.sha256 ~= entry.expected.sha256
					or fingerprint.link ~= entry.expected.link
				then
					if pending_generations[plan.generation] then
						conflict(
							entry,
							"unrecorded target differs from this generation's pending attempt; inspect the journal"
						)
					end
					conflict(
						entry,
						"first adoption of an existing unrecorded target; inspect it and remove or back it up explicitly"
					)
				end
			else
				conflict(entry, "backend-rendered target exists without an owned record")
			end
		end
	end
	for _, removal in ipairs(plan.removals) do
		local recorded = journal and journal.targets and journal.targets[removal.target]
		assert(recorded, "removal of " .. removal.target .. " has no owned record")
		local fingerprint = state.target_fingerprint(removal.target)
		assert(
			fingerprint ~= nil
				and fingerprint.type == recorded.type
				and fingerprint.sha256 == recorded.sha256
				and fingerprint.link == recorded.link,
			"removal of " .. removal.target .. " conflicts: the target changed since the last successful apply"
		)
	end
end

---Fingerprint owned targets after a successful backend apply.
local function applied_fingerprints(plan)
	local fingerprints = {}
	for _, entry in ipairs(plan.entries) do
		local fingerprint = state.target_fingerprint(entry.target)
		assert(fingerprint, "owned target missing after apply: " .. entry.target)
		fingerprint.owner = entry.owner
		fingerprint.operation = entry.operation
		fingerprint.shared = entry.shared or nil
		fingerprint.source_fingerprint = entry.fingerprint
		fingerprints[entry.target] = fingerprint
	end
	return fingerprints
end

---Materialize home state: publish the verified immutable generation, check
---target preconditions, apply through the backend, then record last-applied
---metadata. Held under the fail-closed per-target lock throughout.
function M.apply(plan)
	return state.with_lock("apply", function()
		local generation = publish(plan)
		check_preconditions(plan)
		state.write_pending({
			generation = plan.generation,
			at = os.time(),
			pid = vim.uv.os_getpid(),
			entries = #plan.entries,
			targets = vim.tbl_map(function(entry)
				return entry.target
			end, plan.entries),
		})
		local ok, failure = pcall(run_backend, "apply", generation, {})
		if not ok then
			state.write_failed({
				generation = plan.generation,
				at = os.time(),
				pid = vim.uv.os_getpid(),
				error = tostring(failure),
				note = "partial apply is possible; recovery is conflict-aware, never a blind replay",
			})
			error(failure)
		end
		state.record_applied(plan.generation, applied_fingerprints(plan), plan.fragments_journal)
		state.clear_pending(plan.generation)
		return generation
	end)
end

---Show pending home-state changes with the same desired-state generation as
---apply. Diff executes no setup, sync, verify or retirement handlers and does
---not advance the journal.
function M.diff(plan)
	return state.with_lock("diff", function()
		local generation = publish(plan)
		run_backend("diff", generation, {})
		return generation
	end)
end

return M
