local repository = vim.fn.getcwd()
local root = vim.fs.joinpath(repository, "workstation")
package.path = table.concat({
	vim.fs.joinpath(root, "?.lua"),
	vim.fs.joinpath(root, "?", "init.lua"),
	vim.fs.joinpath(root, "lua", "?.lua"),
	vim.fs.joinpath(root, "lua", "?", "init.lua"),
	package.path,
}, ";")

local provision = require("workstation.provision")
local provisioner = require("workstation.provisioner")

local scratch = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(scratch, "p")
vim.env.WORKSTATION_CACHE = vim.fs.joinpath(scratch, "cache")
local api = provision.create("linux")

local function sh(command)
	local result = vim.system({ "sh", "-c", command }):wait()
	assert(result.code == 0, ("fixture command failed: %s\n%s"):format(command, result.stderr))
	return vim.trim(result.stdout)
end

local function sha256_of(path)
	return sh(("sha256sum %q | cut -d' ' -f1"):format(path))
end

local function fixture_archive(scratch_path, entries)
	local fixture_dir = vim.fs.joinpath(scratch, ("fixture-%d"):format(os.time() * 1000 % 100000000))
	vim.fn.mkdir(fixture_dir, "p")
	local roots = {}
	for name, contents in pairs(entries) do
		local file = vim.fs.joinpath(fixture_dir, name)
		vim.fn.mkdir(vim.fs.dirname(file), "p")
		local handle = assert(io.open(file, "wb"))
		handle:write(contents)
		handle:close()
		local top = name:match("^([^/]+)")
		if not vim.list_contains(roots, top) then
			table.insert(roots, top)
		end
	end
	local archive = vim.fs.joinpath(scratch, scratch_path)
	-- Named members (no leading ./) mirror release-archive layout: prefix/dir/file.
	sh(("tar -czf %q -C %q %s"):format(archive, fixture_dir, table.concat(roots, " ")))
	return archive, fixture_dir
end

local function read_all(path)
	local handle = assert(io.open(path, "rb"))
	local contents = handle:read("*a")
	handle:close()
	return contents
end

local function assert_mode(path, expected_octal)
	local stat = assert(vim.uv.fs_stat(path))
	assert(
		bit.band(stat.mode, tonumber("777", 8)) == tonumber(expected_octal, 8),
		("%s has mode %o, expected %s"):format(path, stat.mode, expected_octal)
	)
end

-- provision.archive installs the pinned member with content and mode intact
do
	local archive = fixture_archive("tool.tar.gz", { ["tool-1.0/bin/tool"] = "payload\n" })
	local dest = vim.fs.joinpath(scratch, "bin", "tool")
	api.archive({
		url = "file://" .. archive,
		sha256 = sha256_of(archive),
		inner_path = "tool-1.0/bin/tool",
		dest = dest,
	})
	assert(read_all(dest) == "payload\n", "archive content mismatch")
	assert_mode(dest, "755")
end

-- skip-if-current: a matching marker plus an existing destination does no work,
-- so a manual modification of the destination survives a re-run
do
	local archive = fixture_archive("skip.tar.gz", { ["app/bin/app"] = "first\n" })
	local dest = vim.fs.joinpath(scratch, "bin", "app")
	local spec = {
		url = "file://" .. archive,
		sha256 = sha256_of(archive),
		inner_path = "app/bin/app",
		dest = dest,
	}
	api.archive(spec)
	local handle = assert(io.open(dest, "wb"))
	handle:write("mutated\n")
	handle:close()
	api.archive(spec)
	assert(read_all(dest) == "mutated\n", "re-run overwrote a destination it should have skipped")
	-- a missing destination always reinstalls
	vim.fn.delete(dest)
	api.archive(spec)
	assert(read_all(dest) == "first\n", "missing destination was not reinstalled")
end

-- checksum mismatch is fatal and leaves no cached artifact behind
do
	local archive = fixture_archive("bad.tar.gz", { ["x/y"] = "data\n" })
	local cache_downloads = vim.fs.joinpath(vim.env.WORKSTATION_CACHE, "downloads")
	local downloads_before = #vim.fn.readdir(cache_downloads)
	local ok, failure = pcall(api.archive, {
		url = "file://" .. archive,
		sha256 = ("f"):rep(64),
		inner_path = "x/y",
		dest = vim.fs.joinpath(scratch, "bin", "bad"),
	})
	assert(not ok, "checksum mismatch did not fail")
	assert(
		tostring(failure):find("checksum mismatch", 1, true),
		"failure did not name the checksum: " .. tostring(failure)
	)
	assert(#vim.fn.readdir(cache_downloads) == downloads_before, "unverified artifact was admitted to the cache")
end

-- provision.directory with exact=true replaces stale entries wholesale
do
	local first = fixture_archive("fonts-v1.tar.gz", { ["a.ttf"] = "a", ["b.ttf"] = "b" })
	local dest = vim.fs.joinpath(scratch, "fonts", "Family")
	api.directory({ url = "file://" .. first, sha256 = sha256_of(first), dest = dest })
	assert(vim.uv.fs_stat(vim.fs.joinpath(dest, "a.ttf")) and vim.uv.fs_stat(vim.fs.joinpath(dest, "b.ttf")))
	vim.fn.writefile({ "rogue" }, vim.fs.joinpath(dest, "rogue.ttf"))

	local second = fixture_archive("fonts-v2.tar.gz", { ["a.ttf"] = "a2" })
	api.directory({ url = "file://" .. second, sha256 = sha256_of(second), dest = dest })
	assert(vim.uv.fs_stat(vim.fs.joinpath(dest, "a.ttf")), "exact directory lost its shipped entry")
	assert(not vim.uv.fs_stat(vim.fs.joinpath(dest, "rogue.ttf")), "exact directory kept a stale entry")
	assert(not vim.uv.fs_stat(vim.fs.joinpath(dest, "b.ttf")), "exact directory kept a removed entry")
end

-- provisioner argv targets the repo's chezmoi source with an explicit destination
do
	local source = provisioner.chezmoi_source()
	assert(vim.uv.fs_stat(source), "provisioner could not locate the chezmoi source")
	assert(vim.fs.basename(provisioner.repo_root()) ~= "", "provisioner repo root resolution failed")

	local destination = vim.fs.joinpath(scratch, "home")
	vim.fn.mkdir(destination, "p")
	local argv =
		provisioner.argv("apply", { dry_run = true, destination = destination, exclude = { "scripts", "externals" } })
	assert(#argv >= 9, "unexpected argv length")
	assert(vim.tbl_contains(argv, "--source") and vim.tbl_contains(argv, source), "argv misses the explicit source")
	assert(
		vim.tbl_contains(argv, "--destination") and vim.tbl_contains(argv, destination),
		"argv misses the explicit destination"
	)
	assert(vim.tbl_contains(argv, "--exclude") and vim.tbl_contains(argv, "scripts"), "argv does not exclude scripts")

	local result = vim.system(argv):wait()
	assert(result.code == 0, ("chezmoi dry-run failed: %s%s"):format(result.stdout or "", result.stderr or ""))
end

print("provision primitive tests passed")
