local paths = require("workstation.paths")
local versions = require("workstation.versions")

local M = {}

function M.new(host)
	local adapter = vim.tbl_extend("force", {}, host)
	-- versions.node is nil on a fresh host (before the first apply); status and
	-- bootstrap must still work, so the managed node bin joins PATH only once
	-- the pin is known.
	local node_bin_dir = versions.node ~= nil
			and paths.join(paths.local_dir, "opt", "nvm", "versions", "node", "v" .. versions.node, "bin")
		or nil
	adapter.nvim = paths.join(paths.local_dir, "bin", "nvim")

	function adapter.tool(name)
		return paths.join(paths.local_dir, "bin", name)
	end

	function adapter.nvim_data()
		return paths.join(vim.env.XDG_DATA_HOME or paths.join(paths.local_dir, "share"), "nvim")
	end

	function adapter.configure_runtime()
		local path_entries = {}
		if node_bin_dir ~= nil then
			table.insert(path_entries, node_bin_dir)
		end
		table.insert(path_entries, paths.join(paths.local_dir, "bin"))
		table.insert(path_entries, vim.env.PATH or "")
		vim.env.PATH = table.concat(path_entries, ":")
		vim.env.XDG_DATA_HOME = vim.env.XDG_DATA_HOME or paths.join(paths.local_dir, "share")
		vim.env.XDG_STATE_HOME = vim.env.XDG_STATE_HOME or paths.join(paths.local_dir, "state")
		vim.env.XDG_CACHE_HOME = vim.env.XDG_CACHE_HOME or paths.join(paths.home, ".cache")
	end

	return adapter
end

return M
