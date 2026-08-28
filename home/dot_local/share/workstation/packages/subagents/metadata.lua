local M = {}

local function permission_bits(mode)
	return mode % 512
end

function M.verify(directory_stat, config_stat, uid)
	assert(directory_stat.type == "directory", "subagents config parent must be a directory")
	assert(config_stat.type == "file", "subagents config must be a regular file")
	assert(permission_bits(directory_stat.mode) == 448, "subagents config directory must have mode 0700")
	assert(permission_bits(config_stat.mode) == 384, "subagents config must have mode 0600")
	assert(directory_stat.uid == uid, "subagents config directory must be owned by the current user")
	assert(config_stat.uid == uid, "subagents config must be owned by the current user")
end

return M
