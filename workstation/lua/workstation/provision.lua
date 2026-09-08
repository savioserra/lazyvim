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

local function extract(spec, archive, staging)
	local kind = spec.format or (spec.url:match("%.zip$") and "zip" or "tar")
	assert(kind == "tar" or kind == "zip", "unsupported archive format")
	local listing = kind == "zip" and commands.capture("unzip", { "-Z1", archive })
		or commands.capture("tar", { "-tf", archive })
	for name in listing:gmatch("[^\n]+") do
		safe_member(name)
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
local function manifest(platform, root)
	local result = {}
	local function visit(path, name)
		local stat = assert(vim.uv.fs_lstat(path))
		local entry = { type = stat.type, mode = bit.band(stat.mode, 511) }
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
				manifest(platform, content)
				if kind == "archive" then
					safe_member(assert(spec.inner_path, "inner_path required"))
					content = paths.join(content, spec.inner_path)
				end
			end
			if kind ~= "directory" then
				assert(vim.uv.fs_lstat(content).type == "file", "archive member must be a regular file")
				assert(vim.uv.fs_chmod(content, assert(tonumber(spec.mode or "755", 8))))
			end
			local expected = manifest(platform, content)
			local exact = kind ~= "directory" or spec.exact ~= false
			if matches(platform, spec.dest, expected, exact) then
				return
			end
			if not exact and exists(spec.dest) then
				assert(vim.uv.fs_lstat(spec.dest).type == "directory", "non-exact destination must be a directory")
				commands.capture("cp", { "-R", "-P", spec.dest, merged })
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
