local paths = require("workstation.paths")

-- Target-private engine state: immutable content-addressed source generations,
-- a fail-closed per-target operation lock and the private journal of owned
-- target fingerprints. Everything lives under the destination home's
-- .local/state/workstation tree, never in ambient XDG roots, the source
-- checkout or Git. Journal files never contain home-file bodies or secrets,
-- only generated-source data and fingerprint/ownership metadata.

local M = {}

local sequence = 0

function M.root()
	local root = paths.join(paths.local_dir, "state", "workstation")
	vim.fn.mkdir(root, "p")
	local stat = assert(vim.uv.fs_stat(root))
	assert(stat.type == "directory", "engine state root is not a directory: " .. root)
	assert(vim.uv.fs_chmod(root, 448))
	return root
end

function M.generations_root()
	local root = paths.join(M.root(), "generations")
	vim.fn.mkdir(root, "p")
	assert(vim.uv.fs_chmod(root, 448))
	return root
end

function M.journal_root()
	local root = paths.join(M.root(), "journal")
	vim.fn.mkdir(root, "p")
	assert(vim.uv.fs_chmod(root, 448))
	return root
end

local function read_json(path)
	local file = io.open(path, "rb")
	if not file then
		return nil
	end
	local contents = file:read("*a")
	file:close()
	return vim.json.decode(contents)
end

local function write_json(path, value)
	sequence = sequence + 1
	local temporary = ("%s.%d-%d.tmp"):format(path, vim.uv.os_getpid(), sequence)
	local file = assert(io.open(temporary, "wb"))
	assert(file:write(vim.json.encode(value)))
	file:close()
	assert(vim.uv.fs_chmod(temporary, 384))
	assert(vim.uv.fs_rename(temporary, path))
end

function M.sha256(contents)
	return vim.fn.sha256(contents)
end

local function fingerprint_path(target)
	return paths.join(paths.home, target)
end

---Fingerprint actual owned target state. Reads only metadata, link values and
---content digests; home-file bodies are never copied into engine state.
function M.target_fingerprint(target)
	local path = fingerprint_path(target)
	local stat = vim.uv.fs_lstat(path)
	if not stat then
		return nil
	end
	local record = { type = stat.type, mode = bit.band(stat.mode, 4095) }
	if stat.type == "file" then
		local file = assert(io.open(path, "rb"))
		local contents = file:read("*a")
		file:close()
		record.sha256 = M.sha256(contents)
	elseif stat.type == "link" then
		record.link = assert(vim.uv.fs_readlink(path))
	elseif stat.type ~= "directory" then
		return nil, "unsupported owned target type at " .. path
	end
	return record
end

---Fail-closed per-target lock. Held through source publication, backend apply
---and journal completion. Stale locks are never stolen; recovery is an
---inspected operator action.
function M.acquire_lock(purpose)
	local root = M.root()
	local lock_path = paths.join(root, "apply.lock")
	local token = ("%d-%d-%s"):format(vim.uv.os_getpid(), os.time(), tostring(math.random(1e9)))
	local file, open_error = vim.uv.fs_open(lock_path, "wx", 384)
	if not file then
		local existing = read_json(lock_path)
		error(
			("workstation state is locked by another operation (%s); inspect %s and the recorded owner before removing it: %s"):format(
				purpose,
				lock_path,
				vim.json.encode(existing or { note = "unreadable lock" })
			),
			0
		)
	end
	assert(vim.uv.fs_close(file))
	assert(pcall(write_json, lock_path, {
		token = token,
		pid = vim.uv.os_getpid(),
		purpose = purpose,
		started = os.time(),
	}))
	return {
		path = lock_path,
		token = token,
		release = function(self)
			local recorded = read_json(self.path)
			if recorded and recorded.token == self.token then
				vim.fn.delete(self.path)
			end
		end,
	}
end

---Run `callback` while holding the per-target lock, releasing only this
---invocation's own lock on any exit path.
function M.with_lock(purpose, callback)
	local lock = M.acquire_lock(purpose)
	local ok, result = pcall(callback)
	if ok then
		lock:release()
		return result
	end
	lock:release()
	error(result)
end

function M.applied_record()
	return read_json(paths.join(M.journal_root(), "applied.json"))
end

function M.pending_records()
	local directory = paths.join(M.journal_root(), "pending")
	vim.fn.mkdir(directory, "p")
	local records = {}
	for name in vim.fs.dir(directory) do
		local record = read_json(paths.join(directory, name))
		if record then
			record.file = name
			table.insert(records, record)
		end
	end
	table.sort(records, function(left, right)
		return left.file < right.file
	end)
	return records
end

function M.write_pending(record)
	local directory = paths.join(M.journal_root(), "pending")
	vim.fn.mkdir(directory, "p")
	write_json(paths.join(directory, record.generation .. ".json"), record)
end

function M.clear_pending(generation)
	vim.fn.delete(paths.join(paths.join(M.journal_root(), "pending"), generation .. ".json"))
end

---Failed attempts are preserved as private evidence; there is no automatic
---generation or journal garbage collection in this slice.
function M.write_failed(record)
	local directory = paths.join(M.journal_root(), "failed")
	vim.fn.mkdir(directory, "p")
	sequence = sequence + 1
	write_json(paths.join(directory, ("%s-%d-%d.json"):format(record.generation, os.time(), sequence)), record)
end

function M.record_applied(generation, fingerprints, fragments)
	write_json(paths.join(M.journal_root(), "applied.json"), {
		generation = generation,
		at = os.time(),
		targets = fingerprints,
		fragments = fragments or {},
	})
end

return M
