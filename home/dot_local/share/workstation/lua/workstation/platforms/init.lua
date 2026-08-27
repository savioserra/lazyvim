local module
if vim.fn.has("win32") == 1 then
	module = "windows"
elseif vim.fn.has("mac") == 1 then
	module = "macos"
elseif vim.fn.has("linux") == 1 then
	module = "linux"
else
	error("unsupported platform: " .. (vim.uv.os_uname().sysname or "unknown"))
end
return require("workstation.platforms." .. module)
