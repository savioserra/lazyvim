local repository = vim.fn.getcwd()
local file = assert(io.open(repository .. "/.luarc.json", "r"))
local config = vim.json.decode(file:read("*a"))
file:close()
local search = assert(config["runtime.path"], "LuaLS needs the engine's module search paths")

-- Resolve the same module names used by engine/package source. Merely having
-- lua_ls attached does not prove it can follow imports for gd/references.
for module, expected in pairs({
	["workstation.commands"] = "workstation/lua/workstation/commands.lua",
	["workstation.provision.recipes"] = "workstation/lua/workstation/provision/recipes.lua",
	["packages.nvim.leaf"] = "workstation/packages/nvim/leaf.lua",
	["packages.foundation"] = "workstation/packages/foundation/init.lua",
}) do
	local resolved
	for _, pattern in ipairs(search) do
		assert(pattern:sub(1, 1) ~= "/", "LuaLS paths must be repository-relative")
		local candidate = pattern:gsub("%?", (module:gsub("%.", "/")))
		if vim.uv.fs_stat(repository .. "/" .. candidate) then
			resolved = candidate
			break
		end
	end
	assert(resolved == expected, "LuaLS cannot resolve " .. module .. " to its owning source")
end
print("Lua workspace tests passed (portable engine and package module resolution)")
