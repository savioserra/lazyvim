local paths = require("workstation.paths")

local module_path = debug.getinfo(1, "S").source:gsub("^@", "")
local runtime_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(module_path))))
local versions = vim.json.decode(paths.read(paths.join(runtime_root, "versions.json")))
if vim.fn.has("mac") == 1 and jit.arch == "x64" then
	versions.fd = versions.fd_darwin_x86_64
end
-- .node-version only exists after the first apply; status and bootstrap must
-- stay usable on a fresh host, so its absence yields nil instead of an error.
-- `workstation apply` refreshes this value after chezmoi materializes the file.
local ok, node_version = pcall(paths.read, paths.join(paths.home, ".node-version"))
versions.node = (ok and node_version and node_version ~= "") and vim.trim(node_version) or nil
return versions
