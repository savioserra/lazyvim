local repository = vim.fn.getcwd()
assert(vim.env.WORKSTATION_HOME == vim.env.HOME, "test requires a fresh isolated HOME")
assert(vim.uv.fs_stat(vim.env.HOME .. "/.config/nvim") == nil, "do not run against an applied home")
package.path = repository .. "/workstation/lua/?.lua;" .. repository .. "/workstation/?.lua;" .. package.path
local leaf = require("packages.nvim.leaf")
local paths = require("workstation.paths")
local context = { paths = paths, platform = { nvim = vim.v.progpath } }

-- Exercise the real sibling child through both command paths, without loading
-- plugins, syncing application state, or needing any installed language tools.
assert(leaf.run_child(context, "messages", {}) == "")
leaf.run_child(context, "messages", {}, true)
print("nvim leaf tests passed (real sibling child, isolated headless messages, capture/execute)")
