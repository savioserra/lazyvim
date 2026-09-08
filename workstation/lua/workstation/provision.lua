local commands = require("workstation.commands")
local paths = require("workstation.paths")

-- Provision primitives: how capability setup handlers materialize pinned remote
-- assets (archives, single files, engine-managed directories) on the host.
-- Contracts:
--   * every remote asset requires a sha256 pin; downloads are verified before use
--   * installs are atomic: extraction happens in a staging sibling, then rename
--   * assets are cached content-addressed under the provision cache root
--   * a successful install records an identity marker; matching dest + marker skips work
--   * platform differences stay here (sha256sum vs shasum, tar vs unzip), never in packages

local M = {}

local function is_darwin(platform)
	return platform == "darwin"
end

---@param platform string
---@param path string
---@return string hex digest
local function file_sha256(platform, path)
	local output
	if is_darwin(platform) then
		output = commands.capture("shasum", { "-a", "256", path })
	else
		output = commands.capture("sha256sum", { path })
	end
	local digest = output:match("%x+")
	assert(digest, ("unable to read sha256 of %s"):format(path))
	return digest:lower()
end

local function normalize_sha256(value)
	local digest = assert(type(value) == "string" and value:lower():gsub("%s", ""), "sha256 pin is required")
	assert(#digest == 64, "sha256 pin must be a 64-character hex digest")
	return digest
end

local function normalize_mode(mode)
	-- Mode is an octal string (tar/shell convention, e.g. "755"); default is executable.
	return tonumber(mode or "755", 8)
end

local function cache_root()
	return vim.env.WORKSTATION_CACHE
		or paths.join(vim.env.XDG_CACHE_HOME or paths.join(paths.home, ".cache"), "workstation", "provision")
end

local function identity(spec)
	return table.concat(
		{ spec.url, spec.sha256, spec.dest, spec.inner_path or "", spec.mode or "", tostring(spec.exact) },
		"\n"
	)
end

---@param key string
---@return string djb2 hex digest
local function short_hash(key)
	local hash = 5381
	for index = 1, #key do
		hash = (hash * 33 + key:byte(index)) % 0x100000000
	end
	return ("%08x"):format(hash)
end

local function marker_path(key)
	return paths.join(cache_root(), "installed", short_hash(key))
end

---Skip only when the destination exists AND the recorded install identity matches.
local function up_to_date(key, dest)
	if not paths.exists(dest) then
		return false
	end
	local marker = marker_path(key)
	return paths.exists(marker) and vim.trim(paths.read(marker)) == key
end

local function record_marker(key)
	local marker = marker_path(key)
	vim.fn.mkdir(vim.fs.dirname(marker), "p")
	paths.write(marker, key)
end

---Download once into the content-addressed cache; verify before admitting.
local function ensure_downloaded(platform, spec)
	local downloads = paths.join(cache_root(), "downloads")
	local cached = paths.join(downloads, spec.sha256)
	if paths.exists(cached) then
		return cached
	end
	vim.fn.mkdir(downloads, "p")
	local partial = cached .. ".part"
	commands.capture("curl", { "-fSL", "--retry", "3", "-o", partial, spec.url })
	local ok, failure
	ok, failure = pcall(file_sha256, platform, partial)
	if ok and failure ~= spec.sha256 then
		ok = false
		failure = ("provision checksum mismatch for %s: expected %s, got %s"):format(spec.url, spec.sha256, failure)
	end
	if not ok then
		vim.fn.delete(partial)
		error(failure)
	end
	assert(vim.uv.fs_rename(partial, cached))
	return cached
end

local function archive_kind(url)
	if url:match("%.zip$") then
		return "zip"
	end
	return "tar"
end

---Extract a single archive member into the staging directory; returns its path.
local function extract_member(archive, inner_path, staging)
	vim.fn.mkdir(staging, "p")
	if archive_kind(archive) == "zip" then
		commands.execute("unzip", { "-o", archive, inner_path, "-d", staging })
	else
		commands.execute("tar", { "-xf", archive, "-C", staging, inner_path })
	end
	local member = paths.join(staging, inner_path)
	assert(paths.exists(member), ("archive member missing after extraction: %s"):format(inner_path))
	return member
end

---Extract an entire archive into the staging directory.
local function extract_all(archive, staging)
	vim.fn.mkdir(staging, "p")
	if archive_kind(archive) == "zip" then
		commands.execute("unzip", { "-o", archive, "-d", staging })
	else
		commands.execute("tar", { "-xf", archive, "-C", staging })
	end
end

local staging_sequence = 0

local function fresh_staging(dest)
	-- Unique within the process (pid + monotonic counter): a same-second second
	-- caller must never regenerate and delete a live staging path.
	staging_sequence = staging_sequence + 1
	local staging = ("%s.provision-staging-%d-%d"):format(dest, vim.uv.os_getpid(), staging_sequence)
	vim.fn.delete(staging, "rf")
	return staging
end

local function install_file(source, dest, mode)
	vim.fn.mkdir(vim.fs.dirname(dest), "p")
	local staging = fresh_staging(dest) .. ".file"
	vim.fn.delete(staging)
	assert(vim.uv.fs_copyfile(source, staging))
	assert(vim.uv.fs_chmod(staging, mode))
	assert(vim.uv.fs_rename(staging, dest))
end

---@param platform string host platform name ("linux" or "darwin")
---@return table provision primitives bound to the platform
function M.create(platform)
	assert(platform == "linux" or platform == "darwin", "unsupported provision platform: " .. tostring(platform))

	local api = {}

	---Install a single file member of a remote archive.
	---    provision.archive{ url=, sha256=, inner_path=, dest=, mode="755" }
	function api.archive(spec)
		assert(
			type(spec) == "table" and spec.url and spec.inner_path and spec.dest,
			"provision.archive requires url, inner_path, dest"
		)
		spec = vim.tbl_extend("force", {}, spec, { sha256 = normalize_sha256(spec.sha256), mode = spec.mode or "755" })
		local key = identity(spec)
		if up_to_date(key, spec.dest) then
			return
		end
		local cached = ensure_downloaded(platform, spec)
		local staging = fresh_staging(spec.dest)
		local member = extract_member(cached, spec.inner_path, staging)
		install_file(member, spec.dest, normalize_mode(spec.mode))
		vim.fn.delete(staging, "rf")
		record_marker(key)
	end

	---Install a remote file verbatim.
	---    provision.file{ url=, sha256=, dest=, mode="755" }
	function api.file(spec)
		assert(type(spec) == "table" and spec.url and spec.dest, "provision.file requires url, dest")
		spec = vim.tbl_extend("force", {}, spec, { sha256 = normalize_sha256(spec.sha256), mode = spec.mode or "755" })
		local key = identity(spec)
		if up_to_date(key, spec.dest) then
			return
		end
		local cached = ensure_downloaded(platform, spec)
		install_file(cached, spec.dest, normalize_mode(spec.mode))
		record_marker(key)
	end

	---Materialize an engine-managed directory from a remote archive.
	---    provision.directory{ url=, sha256=, dest=, exact=true }
	---With exact=true (replacing chezmoi's exact archives) the destination is
	---replaced wholesale, so stale entries the archive no longer ships disappear.
	function api.directory(spec)
		assert(type(spec) == "table" and spec.url and spec.dest, "provision.directory requires url, dest")
		spec = vim.tbl_extend(
			"force",
			{},
			spec,
			{ sha256 = normalize_sha256(spec.sha256), exact = spec.exact ~= false }
		)
		local key = identity(spec)
		if up_to_date(key, spec.dest) then
			return
		end
		local cached = ensure_downloaded(platform, spec)
		local staging = fresh_staging(spec.dest)
		extract_all(cached, staging)
		vim.fn.mkdir(vim.fs.dirname(spec.dest), "p")
		if spec.exact then
			local retired = ("%s.provision-retired-%d"):format(spec.dest, os.time())
			vim.fn.delete(retired, "rf")
			if paths.exists(spec.dest) then
				assert(vim.uv.fs_rename(spec.dest, retired))
			end
			assert(vim.uv.fs_rename(staging, spec.dest))
			vim.fn.delete(retired, "rf")
		else
			for name, _ in vim.fs.dir(staging) do
				local source = paths.join(staging, name)
				local target = paths.join(spec.dest, name)
				vim.fn.delete(target, "rf")
				assert(vim.uv.fs_rename(source, target))
			end
			vim.fn.delete(staging, "rf")
		end
		record_marker(key)
	end

	return api
end

return M
