local function scan(directory)
	for name, kind in vim.fs.dir(directory) do
		local path = directory .. "/" .. name
		if kind == "directory" then
			scan(path)
		elseif name:match("%.lua$") then
			assert(loadfile(path))
		elseif name:match("%.json$") then
			vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
		end
	end
end
for _, directory in ipairs({ "workstation", "tests", ".github/scripts" }) do
	scan(directory)
end
vim.json.decode(table.concat(vim.fn.readfile(".luarc.json"), "\n"))
print("Lua and JSON syntax checks passed (pinned Neovim)")
