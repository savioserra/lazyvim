local module
if vim.fn.has("win32") == 1 then
	module = "windows"
elseif vim.fn.has("mac") == 1 then
	module = "macos"
else
	module = "linux"
end
return require("lazyvim_capabilities.platforms." .. module)
