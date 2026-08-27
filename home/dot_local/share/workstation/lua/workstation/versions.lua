local paths = require("workstation.paths")

local module_path = debug.getinfo(1, "S").source:gsub("^@", "")
local runtime_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(module_path))))
local versions = vim.json.decode(paths.read(paths.join(runtime_root, "versions.json")))
if vim.fn.has("mac") == 1 and jit.arch == "x64" then
	versions.fd = versions.fd_darwin_x86_64
end
versions.node = vim.trim(paths.read(paths.join(paths.home, ".node-version")))
return versions
