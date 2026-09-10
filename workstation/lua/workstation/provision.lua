local commands = require("workstation.commands")
local paths = require("workstation.paths")

-- Validate downloads on every use and compare installations with verified
-- staging, not a writable identity marker. Core remains unaware of provisioning.
local M = {}

local function sha256(platform, path)
	local output = platform == "darwin" and commands.capture("shasum", { "-a", "256", path })
		or commands.capture("sha256sum", { path })
	return assert(output:match("^(%x+)"), "missing SHA256 digest"):lower()
end

local sequence = 0
local function sibling(dest)
	sequence = sequence + 1
	return ("%s.provision-%d-%d"):format(dest, vim.uv.os_getpid(), sequence)
end

local function exists(path)
	return vim.uv.fs_lstat(path) ~= nil
end

local function download(platform, spec, allow_file_urls)
	assert(type(spec.sha256) == "string" and #spec.sha256 == 64 and spec.sha256:match("^%x+$"), "invalid SHA256 pin")
	assert(spec.url:match("^https://") or (allow_file_urls and spec.url:match("^file://")), "HTTPS URL required")
	local root = paths.join(vim.env.WORKSTATION_CACHE, "downloads")
	vim.fn.mkdir(root, "p")
	local cached = paths.join(root, spec.sha256)
	if exists(cached) then
		local stat = vim.uv.fs_lstat(cached)
		if stat.type == "file" and sha256(platform, cached) == spec.sha256 then
			return cached
		end
		vim.fn.delete(cached, "rf")
	end
	local partial = sibling(cached)
	local ok, failure = pcall(function()
		commands.capture("curl", {
			"--proto",
			allow_file_urls and "=https,file" or "=https",
			"--proto-redir",
			"=https",
			"-fSL",
			"--retry",
			"3",
			"-o",
			partial,
			spec.url,
		})
		assert(sha256(platform, partial) == spec.sha256, "provision checksum mismatch: " .. spec.url)
		assert(vim.uv.fs_rename(partial, cached))
	end)
	vim.fn.delete(partial)
	assert(ok, failure)
	return cached
end

local function safe_member(name)
	assert(name ~= "" and name:sub(1, 1) ~= "/" and not name:find("\\", 1, true), "unsafe archive member")
	for part in name:gmatch("[^/]+") do
		assert(part ~= "..", "unsafe archive member: " .. name)
	end
end

-- GNU tar's default escape style and BSD tar's safe_fprintf octal-escape
-- non-ASCII bytes in the C locale. Normalize only those display octets, once.
-- ASCII escapes (including doubled real backslashes and controls) remain
-- forbidden by safe_member; ZIP listings and inner_path are not tar displays.
local function tar_member(name)
	return (name:gsub("\\([23][0-7][0-7])", function(octal)
		return string.char(tonumber(octal, 8))
	end))
end

-- GNU tar and bsdtar alike report each member's HEADER mode as the first
-- `tar -tvf` field. Extraction cannot be trusted for this: unprivileged tar
-- (GNU 1.35) silently strips setuid/setgid/sticky bits, so the staged tree
-- underreports privileges the archive header still carries.
local function safe_mode(line)
	local perms = line:match("^(%S+)")
	assert(perms and #perms >= 10 and not perms:sub(2, 10):find("[^%a%-]"), "unreadable archive mode: " .. line)
	local special = (perms:sub(4, 4):find("[sS]") and 2048 or 0)
		+ (perms:sub(7, 7):find("[sS]") and 1024 or 0)
		+ (perms:sub(10, 10):find("[tT]") and 512 or 0)
	assert(special == 0, "unsupported special mode in archive: " .. line)
end

local function extract(spec, archive, staging)
	local kind = spec.format or (spec.url:match("%.zip$") and "zip" or "tar")
	assert(kind == "tar" or kind == "zip", "unsupported archive format")
	local listing = kind == "zip" and commands.capture("unzip", { "-Z1", archive })
		or commands.capture("tar", { "-tf", archive })
	for name in listing:gmatch("[^\n]+") do
		safe_member(kind == "tar" and tar_member(name) or name)
	end
	-- Reject special modes from archive headers before extracting: dropped bits
	-- during unprivileged extraction would bypass the manifest staging check.
	if kind == "tar" then
		for line in commands.capture("tar", { "-tvf", archive }):gmatch("[^\n]+") do
			safe_mode(line)
		end
	end
	vim.fn.mkdir(staging, "p")
	if kind == "zip" then
		commands.capture("unzip", { "-o", archive, "-d", staging })
	else
		commands.capture("tar", { "-xf", archive, "-C", staging })
	end
end

-- Includes empty directories, modes and link targets; lstat never follows a
-- destination link while checking completeness. Non-exact trees allow extras.
local function manifest(platform, root, staging)
	local result = {}
	local function visit(path, name)
		local stat = assert(vim.uv.fs_lstat(path))
		local entry = { type = stat.type, mode = bit.band(stat.mode, 4095) }
		-- No shipped artifact needs setuid, setgid or sticky semantics. Reject
		-- privileged staging, but retain all bits when detecting installed drift.
		assert(not staging or bit.band(entry.mode, 3584) == 0, "unsupported special mode in staging: " .. path)
		if stat.type == "file" then
			entry.digest = sha256(platform, path)
		elseif stat.type == "link" then
			entry.link = assert(vim.uv.fs_readlink(path))
			local target = vim.fs.normalize(paths.join(vim.fs.dirname(path), entry.link))
			assert(
				entry.link:sub(1, 1) ~= "/" and target:sub(1, #root + 1) == root .. "/",
				"archive link escapes owned tree"
			)
		elseif stat.type ~= "directory" then
			error("unsupported installed entry: " .. path)
		end
		result[name] = entry
		if stat.type == "directory" then
			for child in vim.fs.dir(path) do
				visit(paths.join(path, child), name .. "/" .. child)
			end
		end
	end
	visit(root, "")
	return result
end

local function matches(platform, dest, expected, exact)
	if not exists(dest) then
		return false
	end
	local ok, actual = pcall(manifest, platform, dest)
	if not ok then
		return false
	end
	for name, entry in pairs(expected) do
		if not vim.deep_equal(entry, actual[name]) then
			return false
		end
	end
	return not exact or vim.deep_equal(actual, expected)
end

local function activate(content, dest)
	local retired = sibling(dest)
	local had_dest = exists(dest)
	if had_dest then
		assert(vim.uv.fs_rename(dest, retired))
	end
	local ok, failure = vim.uv.fs_rename(content, dest)
	if not ok then
		if had_dest then
			assert(
				vim.uv.fs_rename(retired, dest),
				"activation failed; rollback failed; previous installation at " .. retired
			)
		end
		error(failure)
	end
	vim.fn.delete(retired, "rf")
end

-- Overlay shipped members recursively, retaining unrelated mutable state.
local function overlay(source, target)
	local stat = assert(vim.uv.fs_lstat(source))
	local existing = vim.uv.fs_lstat(target)
	if stat.type == "directory" then
		if existing and existing.type ~= "directory" then
			vim.fn.delete(target, "rf")
		end
		vim.fn.mkdir(target, "p")
		for name in vim.fs.dir(source) do
			overlay(paths.join(source, name), paths.join(target, name))
		end
		assert(vim.uv.fs_chmod(target, bit.band(stat.mode, 511)))
	else
		vim.fn.delete(target, "rf")
		assert(vim.uv.fs_rename(source, target))
	end
end

function M.create(platform, options)
	assert(platform == "linux" or platform == "darwin", "unsupported provision platform")
	options = options or {}
	local function install(kind, spec)
		assert(type(spec) == "table" and spec.dest and spec.url, "provision requires dest and url")
		local cached = download(platform, spec, options.allow_file_urls == true)
		vim.fn.mkdir(vim.fs.dirname(spec.dest), "p")
		local staging = sibling(spec.dest)
		local merged = sibling(spec.dest)
		local ok, failure = pcall(function()
			local content
			if kind == "file" then
				assert(vim.uv.fs_copyfile(cached, staging))
				content = staging
			else
				extract(spec, cached, staging)
				content = staging
				for _ = 1, spec.strip_components or 0 do
					local entries = vim.fn.readdir(content)
					assert(#entries == 1, "archive root is not a single directory")
					content = paths.join(content, entries[1])
					assert(vim.uv.fs_lstat(content).type == "directory", "archive root is not a directory")
				end
				-- Validate the complete extracted tree, including link confinement.
				manifest(platform, content, true)
				if kind == "archive" then
					safe_member(assert(spec.inner_path, "inner_path required"))
					content = paths.join(content, spec.inner_path)
				end
			end
			if kind ~= "directory" then
				assert(vim.uv.fs_lstat(content).type == "file", "archive member must be a regular file")
				local mode = assert(tonumber(spec.mode or "755", 8))
				assert(mode >= 0 and mode <= 511, "unsupported special mode in staging")
				assert(vim.uv.fs_chmod(content, mode))
			end
			local expected = manifest(platform, content, true)
			local exact = kind ~= "directory" or spec.exact ~= false
			if matches(platform, spec.dest, expected, exact) then
				return
			end
			if not exact and exists(spec.dest) then
				assert(vim.uv.fs_lstat(spec.dest).type == "directory", "non-exact destination must be a directory")
				-- POSIX -p preserves existing unrelated modes (including special
				-- bits), ownership and timestamps; shipped paths still come solely
				-- from the special-bit-free verified staging tree.
				commands.capture("cp", { "-p", "-R", "-P", spec.dest, merged })
				overlay(content, merged)
				content = merged
			end
			activate(content, spec.dest)
		end)
		vim.fn.delete(staging, "rf")
		vim.fn.delete(merged, "rf")
		assert(ok, failure)
	end
	return {
		file = function(spec)
			install("file", spec)
		end,
		archive = function(spec)
			install("archive", spec)
		end,
		directory = function(spec)
			install("directory", spec)
		end,
	}
end

return M
