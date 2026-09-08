local repository = vim.fn.getcwd()
local scratch = vim.fn.tempname()
vim.env.WORKSTATION_HOME = scratch
package.path = repository .. "/workstation/lua/?.lua;" .. repository .. "/workstation/?.lua;" .. package.path
local commands = require("workstation.commands")
local paths = require("workstation.paths")
local host = vim.uv.os_uname().sysname == "Darwin" and "darwin" or "linux"
local api = require("workstation.provision").create(host, { allow_file_urls = true })
local function digest(path)
	local output = host == "darwin" and commands.capture("shasum", { "-a", "256", path })
		or commands.capture("sha256sum", { path })
	return output:match("^%x+")
end
local count = 0
local function archive(entries, format)
	count = count + 1
	local dir = scratch .. "/fixture-" .. count
	vim.fn.mkdir(dir, "p")
	for name, body in pairs(entries) do
		paths.write(dir .. "/" .. name, body)
	end
	local target = dir .. (format == "zip" and ".zip" or ".tar.gz")
	if format == "zip" then
		dofile(repository .. "/tests/fixtures/zip.lua").write(target, entries)
	else
		commands.capture("tar", { "-czf", target, "-C", dir, "." })
	end
	return { url = "file://" .. target, sha256 = digest(target), format = format or "tar" }, target
end
local function mode(path)
	return bit.band(assert(vim.uv.fs_stat(path)).mode, 511)
end
local function no_staging()
	local found = vim.fn.glob(scratch .. "/**/*.provision-*", false, true)
	assert(#found == 0, "staging leaked: " .. vim.inspect(found))
end
for _, format in ipairs({ "tar", "zip" }) do
	local spec, source = archive({ ["app/bin/tool"] = "trusted\n", ["app/empty/keep"] = "member" }, format)
	spec.dest = scratch .. "/" .. format .. "-tool"
	spec.inner_path = "app/bin/tool"
	api.archive(spec)
	assert(paths.read(spec.dest) == "trusted\n" and mode(spec.dest) == 493)
	paths.write(spec.dest, "tampered\n")
	vim.uv.fs_chmod(spec.dest, 384)
	api.archive(spec)
	assert(paths.read(spec.dest) == "trusted\n" and mode(spec.dest) == 493, "installed bytes/mode not repaired")
	local cached = vim.env.WORKSTATION_CACHE .. "/downloads/" .. spec.sha256
	paths.write(cached, "tampered cache\n")
	vim.fn.delete(spec.dest)
	api.archive(spec)
	assert(paths.read(spec.dest) == "trusted\n" and digest(cached) == spec.sha256, "cache not repaired")
	-- Prove a cache hit reuses verified bytes even when source is unavailable.
	vim.fn.delete(source)
	vim.fn.delete(spec.dest)
	api.archive(spec)
	assert(paths.read(spec.dest) == "trusted\n")
	local tree = vim.tbl_extend(
		"force",
		spec,
		{ dest = scratch .. "/" .. format .. "-tree", strip_components = 1, exact = true }
	)
	api.directory(tree)
	vim.fn.delete(tree.dest .. "/bin/tool")
	paths.write(tree.dest .. "/stale", "rogue")
	api.directory(tree)
	assert(paths.read(tree.dest .. "/bin/tool") == "trusted\n" and not paths.exists(tree.dest .. "/stale"))
	vim.uv.fs_chmod(tree.dest .. "/bin/tool", 448)
	api.directory(tree)
	assert(mode(tree.dest .. "/bin/tool") == 420, "directory member mode not repaired")
	-- Non-exact owns only shipped paths, retaining nested mutable state.
	tree.exact = false
	paths.write(tree.dest .. "/bin/user-state", "retain")
	paths.write(tree.dest .. "/bin/tool", "drift")
	api.directory(tree)
	assert(
		paths.read(tree.dest .. "/bin/user-state") == "retain" and paths.read(tree.dest .. "/bin/tool") == "trusted\n"
	)
	paths.write(cached, "corrupt; source is now unavailable")
	assert(not pcall(api.directory, tree), "corrupt cache silently accepted when reacquisition failed")
	assert(
		paths.read(tree.dest .. "/bin/tool") == "trusted\n" and paths.read(tree.dest .. "/bin/user-state") == "retain"
	)
end
-- Direct file bytes, pin validation and invalid downloads never activate.
do
	local source = scratch .. "/raw"
	paths.write(source, "raw bytes")
	local spec =
		{ url = "file://" .. source, sha256 = digest(source), dest = scratch .. "/raw-installed", mode = "644" }
	api.file(spec)
	paths.write(spec.dest, "changed")
	api.file(spec)
	assert(paths.read(spec.dest) == "raw bytes" and mode(spec.dest) == 420)
	local bad = vim.tbl_extend("force", spec, { sha256 = string.rep("f", 64) })
	local ok, failure = pcall(api.file, bad)
	assert(not ok and tostring(failure):find("checksum mismatch", 1, true))
	assert(paths.read(spec.dest) == "raw bytes")
	assert(not paths.exists(vim.env.WORKSTATION_CACHE .. "/downloads/" .. bad.sha256))
	bad.sha256 = string.rep("z", 64)
	assert(not pcall(api.file, bad))
	assert(not pcall(require("workstation.provision").create(host).file, spec), "production accepted file URL")
end
-- Failed extraction and activation leave the previous good installation intact.
do
	local spec = archive({ ["bin/tool"] = "good" })
	spec.dest = scratch .. "/rollback"
	api.directory(spec)
	local bad = scratch .. "/invalid.tar"
	paths.write(bad, "not an archive")
	assert(not pcall(api.directory, { url = "file://" .. bad, sha256 = digest(bad), dest = spec.dest }))
	assert(paths.read(spec.dest .. "/bin/tool") == "good")
	paths.write(spec.dest .. "/stale", "state")
	local rename = vim.uv.fs_rename
	vim.uv.fs_rename = function(from, to)
		if
			to == spec.dest
			and not paths.exists(spec.dest)
			and paths.exists(from .. "/bin/tool")
			and not paths.exists(from .. "/stale")
		then
			return nil, "injected activation failure"
		end
		return rename(from, to)
	end
	local ok, failure = pcall(api.directory, spec)
	vim.uv.fs_rename = rename
	assert(not ok and tostring(failure):find("injected activation failure", 1, true))
	assert(paths.read(spec.dest .. "/bin/tool") == "good" and paths.read(spec.dest .. "/stale") == "state")
end
-- Deterministic argv smoke: execute a tiny fake backend, never the real source
-- (chezmoi may resolve/download externals even with --exclude externals).
do
	local provisioner = require("workstation.provisioner")
	local destination = scratch .. "/argv-home"
	local argv = provisioner.argv("apply", { dry_run = true, destination = destination })
	assert(argv[2] == "--source" and argv[3] == repository .. "/chezmoi")
	assert(argv[4] == "--destination" and argv[5] == destination)
	assert(argv[6] == "apply" and argv[7] == "--dry-run" and argv[9] == "scripts")
	local log = scratch .. "/backend-argv"
	paths.write(argv[1], "#!/bin/sh\nprintf '%s\\n' \"$@\" > '" .. log .. "'\n")
	vim.uv.fs_chmod(argv[1], 448)
	local result = vim.system(argv):wait()
	assert(result.code == 0 and paths.read(log):find(destination, 1, true))
end
no_staging()
vim.fn.delete(scratch, "rf")
print("provision tests passed (tar/ZIP, cache/installed drift, non-exact state, rollback, offline backend argv)")
