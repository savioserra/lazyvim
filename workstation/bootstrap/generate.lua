-- Developer-only projection generator; end-user bootstrap never invokes Lua.
-- Run pinned nvim -l workstation/bootstrap/generate.lua [--check].
local script = vim.uv.fs_realpath(debug.getinfo(1, "S").source:sub(2))
local root = vim.fs.dirname(vim.fs.dirname(script))
local file = assert(io.open(root .. "/versions.json", "rb"))
local source = file:read("*a")
file:close()
local versions = vim.json.decode(source)
local lines = { "versions-sha256|" .. vim.fn.sha256(source) }
for _, asset in ipairs({ "linux_x86_64", "darwin_arm64" }) do
	table.insert(
		lines,
		table.concat({
			asset,
			versions.neovim,
			versions["neovim_" .. asset .. "_url"]:gsub("{V}", versions.neovim),
			versions["neovim_" .. asset .. "_sha256"],
		}, "|")
	)
end
local output = table.concat(lines, "\n") .. "\n"
local target = root .. "/bootstrap/bootstrap.pins"
if arg[1] == "--check" then
	file = assert(io.open(target, "rb"))
	local actual = file:read("*a")
	file:close()
	assert(actual == output, "bootstrap.pins differs from canonical versions.json; run generate.lua")
else
	file = assert(io.open(target, "wb"))
	assert(file:write(output))
	file:close()
end
