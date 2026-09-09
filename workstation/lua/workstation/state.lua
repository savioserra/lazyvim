local paths = require("workstation.paths")

-- Target-private engine state: immutable content-addressed source generations,
-- a fail-closed per-target operation lock and the private journal of owned
-- target fingerprints. Everything lives under the destination home's
-- .local/state/workstation tree, never in ambient XDG roots, the source
-- checkout or Git. Journal files never contain home-file bodies or secrets,
-- only generated-source data and fingerprint/ownership metadata.
--
-- Filesystem safety: engine-state paths are resolved without following
-- symlinks, must be owned by the current account, and private roots must hold
-- their 0700 mode. Journal-derived identifiers are validated before any path
-- is built from them, and temporary entries are allocated exclusively instead
-- of truncating predictable paths.

local M = {}

local sequence = 0

local function uid()
	return vim.uv.getuid()
end

---Valid content-addressed generation identifier: exactly 64 lowercase hex
---characters. Lua patterns have no counted repetition, so length and alphabet
---are checked separately.
function M.valid_generation_id(id)
	return type(id) == "string" and #id == 64 and id:match("^[0-9a-f]+$") ~= nil
end

---Join a validated relative target to the destination home.
function M.join_home(target)
	assert(type(target) == "string" and target ~= "" and target:sub(1, 1) ~= "/", "invalid relative target")
	assert(not target:find("\0", 1, true) and not target:find("[%c]"), "invalid target characters")
	return paths.join(paths.home, target)
end

---Resolve one engine-state directory with no-follow semantics: every existing
---component below the home must be a real directory owned by the current
---account (never a symlink), missing components are created with `mode`, and
---the final directory is verified to hold exactly `mode` and our ownership.
local function guarded_directory(components, mode, label)
	local current = paths.home
	for index, component in ipairs(components) do
		current = paths.join(current, component)
		local stat = vim.uv.fs_lstat(current)
		if stat then
			assert(stat.type == "directory", label .. " component is not a directory: " .. current)
			assert(stat.uid == uid(), label .. " component is not owned by the current account: " .. current)
			if index == #components then
				assert(vim.uv.fs_chmod(current, mode))
				local verified = assert(vim.uv.fs_lstat(current))
				assert(
					bit.band(verified.mode, 4095) == mode,
					("%s has mode %o, expected %o: %s"):format(label, bit.band(verified.mode, 4095), mode, current)
				)
			end
		else
			assert(vim.uv.fs_mkdir(current, index == #components and mode or 493), "cannot create " .. label)
			local verified = assert(vim.uv.fs_lstat(current))
			assert(
				bit.band(verified.mode, 4095) == (index == #components and mode or 493),
				label .. " was created with the wrong mode: " .. current
			)
		end
	end
	return current
end

function M.root()
	return guarded_directory({ ".local", "state", "workstation" }, 448, "engine state root")
end

function M.generations_root()
	return guarded_directory({ ".local", "state", "workstation", "generations" }, 448, "generations root")
end

function M.journal_root()
	return guarded_directory({ ".local", "state", "workstation", "journal" }, 448, "journal root")
end

---Resolve the generation directory for a journal-derived identifier, refusing
---symlinks and non-directories before any caller reads or writes through it.
function M.generation_directory(id)
	assert(M.valid_generation_id(id), "journal records an invalid generation identifier")
	local directory = paths.join(M.generations_root(), id)
	local stat = vim.uv.fs_lstat(directory)
	if stat then
		assert(stat.type == "directory", "recorded generation is not a directory: " .. directory)
		assert(stat.uid == uid(), "recorded generation is not owned by the current account: " .. directory)
	end
	return directory
end

---Read a private journal file without following symlinks. Returns nil for
---absent entries; malformed content returns nil with a note, never a raw body.
local function read_json(path)
	local stat = vim.uv.fs_lstat(path)
	if not stat then
		return nil
	end
	assert(stat.type == "file", "engine journal entry is not a regular file: " .. path)
	assert(stat.uid == uid(), "engine journal entry is not owned by the current account: " .. path)
	local file = assert(io.open(path, "rb"))
	local contents = file:read("*a")
	file:close()
	local ok, decoded = pcall(vim.json.decode, contents)
	if not ok then
		return nil, "malformed"
	end
	return decoded
end

---Write a private journal file through an exclusively created temporary entry
---in the same directory. Existing paths are never truncated in place.
local function write_json(path, value)
	local root = vim.fs.dirname(path)
	for _ = 1, 64 do
		sequence = sequence + 1
		local temporary = ("%s/%d-%d-%d.tmp"):format(root, vim.uv.os_getpid(), os.time() % 1000000, sequence)
		local file, open_error = vim.uv.fs_open(temporary, "wx", 384)
		if file then
			local payload = vim.json.encode(value)
			assert(vim.uv.fs_write(file, payload))
			assert(vim.uv.fs_close(file))
			assert(vim.uv.fs_rename(temporary, path))
			return
		end
		assert(open_error == "EEXIST", "cannot allocate a private journal temporary: " .. tostring(open_error))
	end
	error("cannot allocate a private journal temporary in " .. root, 0)
end

function M.sha256(contents)
	return vim.fn.sha256(contents)
end

---Fingerprint actual owned target state. Reads only metadata, link values and
---content digests; home-file bodies are never copied into engine state.
function M.target_fingerprint(target)
	local path = M.join_home(target)
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
---inspected operator action. Diagnostics stay bounded: only the recorded
---owner metadata is reported, never a raw lock body.
function M.acquire_lock(purpose)
	local root = M.root()
	local lock_path = paths.join(root, "apply.lock")
	local token = ("%d-%d-%s"):format(vim.uv.os_getpid(), os.time(), tostring(math.random(1e9)))
	local file, open_error = vim.uv.fs_open(lock_path, "wx", 384)
	if not file then
		local existing, note = read_json(lock_path)
		local owner
		if type(existing) == "table" then
			owner = ("token=%s pid=%s purpose=%s started=%s"):format(
				tostring(existing.token),
				tostring(existing.pid),
				tostring(existing.purpose),
				tostring(existing.started)
			)
		else
			owner = "unreadable or malformed lock (" .. tostring(note or existing) .. ")"
		end
		error(
			("workstation state is locked by another operation (%s); inspect %s and the recorded owner before removing it: %s"):format(
				purpose,
				lock_path,
				owner
			),
			0
		)
	end
	assert(vim.uv.fs_close(file))
	write_json(lock_path, {
		token = token,
		pid = vim.uv.os_getpid(),
		purpose = purpose,
		started = os.time(),
	})
	return {
		path = lock_path,
		token = token,
		release = function(self)
			local recorded = read_json(self.path)
			if type(recorded) == "table" and recorded.token == self.token then
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
	local stat = vim.uv.fs_lstat(directory)
	if not stat then
		return {}
	end
	assert(stat.type == "directory", "pending journal root is not a directory")
	local records = {}
	for name in vim.fs.dir(directory) do
		local record = read_json(paths.join(directory, name))
		if type(record) == "table" then
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
	assert(M.valid_generation_id(record.generation), "pending record has an invalid generation identifier")
	local directory = paths.join(M.journal_root(), "pending")
	local stat = vim.uv.fs_lstat(directory)
	if not stat then
		assert(vim.uv.fs_mkdir(directory, 448), "cannot create the pending journal root")
	end
	write_json(paths.join(directory, record.generation .. ".json"), record)
end

---Resolve pending attempts after a successful apply. Failed-attempt evidence
---stays in failed/; pending/ only ever marks attempts without a verdict, and
---any later successful application supersedes them.
function M.clear_pending()
	local directory = paths.join(M.journal_root(), "pending")
	local stat = vim.uv.fs_lstat(directory)
	if not stat then
		return
	end
	assert(stat.type == "directory", "pending journal root is not a directory")
	for name in vim.fs.dir(directory) do
		assert(name:match("^[0-9a-f]+%.json$") ~= nil, "refusing to delete an unexpected pending entry: " .. name)
		vim.fn.delete(paths.join(directory, name))
	end
end

---Failed attempts are preserved as private evidence; there is no automatic
---generation or journal garbage collection in this slice.
function M.write_failed(record)
	assert(M.valid_generation_id(record.generation), "failed record has an invalid generation identifier")
	local directory = paths.join(M.journal_root(), "failed")
	local stat = vim.uv.fs_lstat(directory)
	if not stat then
		assert(vim.uv.fs_mkdir(directory, 448), "cannot create the failed journal root")
	end
	sequence = sequence + 1
	write_json(paths.join(directory, ("%s-%d-%d.json"):format(record.generation, os.time(), sequence)), record)
end

---Record the successful application of one generation. The journal keeps the
---manifest and a source-name index so later previews bind to a verifiable
---prior baseline, plus a monotonic revision every plan is stamped against.
function M.record_applied(generation, fingerprints, fragments, manifest, source_index)
	assert(M.valid_generation_id(generation), "applied record has an invalid generation identifier")
	local previous = M.applied_record()
	write_json(paths.join(M.journal_root(), "applied.json"), {
		generation = generation,
		revision = (type(previous) == "table" and previous.revision or 0) + 1,
		at = os.time(),
		targets = fingerprints,
		fragments = fragments or {},
		manifest = manifest,
		source_index = source_index,
	})
end

return M
