local paths = require("setup.paths")
local versions = require("setup.versions")

local M = {}

function M.new(platform)
	local adapter = vim.tbl_extend("force", {}, platform)
	adapter.node = paths.join(paths.local_dir, "opt", "nvm", "versions", "node", "v" .. versions.node, "bin", "node")
	adapter.nvim = paths.join(paths.local_dir, "bin", "nvim")

	function adapter.tool(name)
		return paths.join(paths.local_dir, "bin", name)
	end

	function adapter.nvim_data()
		return paths.join(vim.env.XDG_DATA_HOME or paths.join(paths.local_dir, "share"), "nvim")
	end

	function adapter.configure_runtime()
		vim.env.PATH =
			table.concat({ vim.fs.dirname(adapter.node), paths.join(paths.local_dir, "bin"), vim.env.PATH or "" }, ":")
		vim.env.XDG_DATA_HOME = vim.env.XDG_DATA_HOME or paths.join(paths.local_dir, "share")
		vim.env.XDG_STATE_HOME = vim.env.XDG_STATE_HOME or paths.join(paths.local_dir, "state")
		vim.env.XDG_CACHE_HOME = vim.env.XDG_CACHE_HOME or paths.join(paths.home, ".cache")
	end

	function adapter.configure_node()
		paths.write(paths.join(paths.local_dir, "opt", "nvm", "alias", "default"), versions.node .. "\n")
	end

	function adapter.verify_node()
		local configured_version = vim.trim(paths.read(paths.join(paths.local_dir, "opt", "nvm", "alias", "default")))
		assert(
			configured_version == versions.node,
			("expected nvm default %s, got %s"):format(versions.node, configured_version)
		)
	end

	return adapter
end

return M
