local provision = require("workstation.provision.recipes")

-- TEMPORARY migration checkpoint adapter (provider-api-typescript-checkpoint).
-- It consumes the legacy checked-in chezmoi tree as a clearly marked migration
-- input for contributions whose owners are not migrated yet, reading the old
-- source files at declaration time. This package is NOT a permanent adapter or
-- catch-all owner: the remaining owners migrate in the next step and this file
-- plus the legacy tree are then deleted together.

local module_path = debug.getinfo(1, "S").source:gsub("^@", "")
local package_root = module_path:sub(1, #module_path - #"/init.lua")
local legacy_root = package_root:gsub("/workstation/packages/[^/]+$", "/chezmoi")

local nvim_files = {
	"init.lua",
	"lazyvim.json",
	"lazy-lock.json",
	"mason-lock.json",
	"neoconf.json",
	"stylua.toml",
	".gitignore",
	"lua/config/autocmds.lua",
	"lua/config/keymaps.lua",
	"lua/config/lazy.lua",
	"lua/config/options.lua",
	"lua/config/sync.lua",
	"lua/plugins/debugging.lua",
	"lua/plugins/editor.lua",
	"lua/plugins/lsp.lua",
	"lua/plugins/mason-lock.lua",
	"lua/plugins/mason.lua",
	"lua/plugins/testing.lua",
	"lua/plugins/theme.lua",
	"lua/plugins/treesitter.lua",
	"lua/plugins/ui.lua",
}

local notifier_files = {
	"README.md",
	"extensions/ntfy-notifier.ts",
	"package.json",
	"src/ntfy.js",
	"test/ntfy.test.mjs",
}

local function read(path)
	local file = assert(io.open(legacy_root .. "/" .. path, "rb"))
	local contents = file:read("*a")
	file:close()
	assert(contents ~= "", "legacy migration input is empty: " .. path)
	return contents
end

return function()
	local contributes = {}
	for _, name in ipairs(nvim_files) do
		table.insert(
			contributes,
			provision.chezmoi({
				target = ".config/nvim/" .. name,
				kind = "file",
				content = read("dot_config/nvim/" .. name),
			})
		)
	end
	table.insert(contributes, provision.chezmoi({ target = ".pi/agent", kind = "directory", private = true }))
	for _, skill in ipairs({ "lazyvim", "secrets" }) do
		table.insert(
			contributes,
			provision.chezmoi({
				target = (".pi/agent/skills/%s/SKILL.md"):format(skill),
				kind = "file",
				content = read(("dot_pi/private_agent/skills/%s/SKILL.md"):format(skill)),
			})
		)
	end
	for _, name in ipairs(notifier_files) do
		table.insert(
			contributes,
			provision.chezmoi({
				target = ".pi/agent/extensions/ntfy-notifier/" .. name,
				kind = "file",
				content = read("dot_pi/private_agent/extensions/ntfy-notifier/" .. name),
			})
		)
	end
	table.insert(
		contributes,
		provision.chezmoi({
			target = ".config/tmux/tmux.conf",
			kind = "symlink",
			to = "../../.tmux.conf",
		})
	)
	table.insert(
		contributes,
		provision.chezmoi({
			target = ".config/tmux/themes/tmux2k.conf",
			kind = "file",
			content = read("dot_config/tmux/themes/tmux2k.conf"),
		})
	)
	table.insert(
		contributes,
		provision.chezmoi({
			target = ".tmux.conf",
			kind = "file",
			content = read("dot_tmux.conf"),
		})
	)
	table.insert(
		contributes,
		provision.chezmoi({
			target = ".local/bin/go",
			kind = "symlink",
			to = "../opt/go/bin/go",
		})
	)
	return {
		id = "migration-source",
		contributes = contributes,
	}
end
