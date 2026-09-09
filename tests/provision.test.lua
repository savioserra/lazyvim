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
local function archive(entries, format, modes)
	count = count + 1
	local dir = scratch .. "/fixture-" .. count
	vim.fn.mkdir(dir, "p")
	for name, body in pairs(entries) do
		paths.write(dir .. "/" .. name, body)
	end
	for name, permissions in pairs(modes or {}) do
		assert(vim.uv.fs_chmod(dir .. "/" .. name, permissions))
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
	return bit.band(assert(vim.uv.fs_stat(path)).mode, 4095)
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
	-- Inert fixture bytes only: inspect special-bit drift, never execute it.
	for _, permissions in ipairs({ 2541, 1517, 1005 }) do -- 04755, 02755, 01755
		assert(vim.uv.fs_chmod(spec.dest, permissions))
		assert(mode(spec.dest) == permissions, "fixture special bits not set")
		api.archive(spec)
		assert(mode(spec.dest) == 493, "installed special-bit drift not repaired")
	end
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
	local root_mode, member_mode = mode(tree.dest), mode(tree.dest .. "/bin/tool")
	assert(vim.uv.fs_chmod(tree.dest, root_mode + 512)) -- sticky exact root
	assert(vim.uv.fs_chmod(tree.dest .. "/bin/tool", member_mode + 2048))
	assert(mode(tree.dest) == root_mode + 512 and mode(tree.dest .. "/bin/tool") == member_mode + 2048)
	api.directory(tree)
	assert(
		mode(tree.dest) == root_mode and mode(tree.dest .. "/bin/tool") == member_mode,
		"exact special-bit drift not repaired"
	)
	-- Non-exact owns only shipped paths, retaining nested mutable state.
	tree.exact = false
	paths.write(tree.dest .. "/bin/user-state", "retain")
	paths.write(tree.dest .. "/bin/tool", "drift")
	assert(vim.uv.fs_chmod(tree.dest .. "/bin/user-state", 936)) -- unrelated inert 01650
	paths.write(tree.dest .. "/user-dir/state", "retain nested")
	assert(vim.uv.fs_chmod(tree.dest .. "/user-dir", 960)) -- unrelated 01700
	assert(mode(tree.dest .. "/bin/user-state") == 936 and mode(tree.dest .. "/user-dir") == 960)
	api.directory(tree)
	assert(mode(tree.dest .. "/bin/user-state") == 936, "unrelated non-exact mode changed")
	assert(mode(tree.dest .. "/user-dir") == 960 and paths.read(tree.dest .. "/user-dir/state") == "retain nested")
	assert(
		paths.read(tree.dest .. "/bin/user-state") == "retain" and paths.read(tree.dest .. "/bin/tool") == "trusted\n"
	)
	paths.write(cached, "corrupt; source is now unavailable")
	assert(not pcall(api.directory, tree), "corrupt cache silently accepted when reacquisition failed")
	assert(
		paths.read(tree.dest .. "/bin/tool") == "trusted\n" and paths.read(tree.dest .. "/bin/user-state") == "retain"
	)
end
-- GNU/BSD tar display non-ASCII octets as octal in C locale. These are
-- real inert archives and real tar children, not a mocked Unicode listing.
do
	local capture = commands.capture
	local extracts, listing = 0, nil
	commands.capture = function(command, args, options)
		if command == "tar" then
			options = vim.tbl_extend("force", options or {}, { env = { LC_ALL = "C" } })
			if args[1] == "-xf" then
				extracts = extracts + 1
			end
		end
		local result = capture(command, args, options)
		if command == "tar" and args[1] == "-tf" then
			listing = result
		end
		return result
	end
	local member = "app/Running 'nvm alias ˂name˃'"
	local spec = archive({ [member] = "unicode bytes" })
	spec.dest = scratch .. "/unicode"
	api.directory(spec)
	assert(listing:find("\\313\\202", 1, true), "C-locale tar did not exercise octal display escaping")
	assert(paths.read(spec.dest .. "/" .. member) == "unicode bytes")
	api.directory(spec)
	assert(paths.read(spec.dest .. "/" .. member) == "unicode bytes", "cached Unicode staging changed names")

	local tar = dofile(repository .. "/tests/fixtures/tar.lua")
	for i, name in ipairs({
		"app/real\\backslash",
		"app/literal\\313\\202", -- literal spelling must not become Unicode
		"app/literal\\134", -- must not be recursively unescaped
		"app/literal\\q",
		"/absolute",
		"../escape",
		"app/../../escape",
		"app/˂/../../../escape",
		"app/line\nbreak",
		"app/tab\tname",
	}) do
		local source = scratch .. "/unsafe-name-" .. i .. ".tar"
		tar.write(source, name, "never extract")
		local before = extracts
		local ok, failure = pcall(api.directory, {
			url = "file://" .. source,
			sha256 = digest(source),
			dest = spec.dest,
		})
		assert(not ok and tostring(failure):find("unsafe archive member", 1, true), tostring(failure))
		assert(extracts == before, "unsafe member reached extraction")
		assert(paths.read(spec.dest .. "/" .. member) == "unicode bytes", "unsafe archive changed installation")
	end
	-- Even octal-looking ZIP names remain literal; tar normalization must not
	-- alter ZIP or caller-provided inner_path semantics.
	local bad = archive({ ["literal\\313\\202"] = "inert" }, "zip")
	bad.dest = spec.dest
	assert(not pcall(api.directory, bad))
	local inner = vim.tbl_extend("force", spec, { inner_path = "app/\\313\\202" })
	assert(not pcall(api.archive, inner))
	-- Unicode acceptance does not waive the complete staging link manifest.
	for i, target in ipairs({ "/outside", "../../outside" }) do
		local source = scratch .. "/unicode-link-" .. i .. ".tar"
		tar.write(source, "app/˂link˃", "", target)
		local ok, failure = pcall(api.directory, {
			url = "file://" .. source,
			sha256 = digest(source),
			dest = spec.dest,
		})
		assert(not ok and tostring(failure):find("archive link escapes owned tree", 1, true), tostring(failure))
		assert(paths.read(spec.dest .. "/" .. member) == "unicode bytes")
	end
	commands.capture = capture
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
	local privileged = vim.tbl_extend("force", spec, { mode = "4755" })
	ok, failure = pcall(api.file, privileged)
	assert(not ok and tostring(failure):find("unsupported special mode", 1, true))
	assert(mode(spec.dest) == 420 and paths.read(spec.dest) == "raw bytes")
end
-- Reject special-bit archive staging instead of silently shipping privileges.
do
	local spec = archive({ ["bin/tool"] = "inert" })
	spec.dest = scratch .. "/special-staging"
	api.directory(spec)
	for _, modes in ipairs({ { ["bin/tool"] = 2541 }, { bin = 1005 } }) do
		local bad = archive({ ["bin/tool"] = "untrusted mode" }, "tar", modes)
		bad.dest = spec.dest
		local ok, failure = pcall(api.directory, bad)
		assert(not ok and tostring(failure):find("unsupported special mode", 1, true), tostring(failure))
		assert(paths.read(spec.dest .. "/bin/tool") == "inert" and mode(spec.dest .. "/bin/tool") == 420)
	end
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
