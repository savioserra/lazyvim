local M = {}

local function lazy_errors()
  local errors = {}
  for plugin_name, plugin in pairs(require("lazy.core.config").plugins) do
    for _, task in ipairs(plugin._.tasks or {}) do
      if task:has_errors() then
        local output = vim.trim(task:output(vim.log.levels.ERROR))
        errors[#errors + 1] = ("%s/%s: %s"):format(plugin_name, task.name, output ~= "" and output or "failed")
      end
    end
  end
  table.sort(errors)
  return errors
end

local function lazy_operation(operation)
  local manage = require("lazy.manage")
  local handler = assert(manage[operation], "unknown lazy operation: " .. operation)
  handler({ wait = true, show = false }):wait()

  local errors = lazy_errors()
  assert(#errors == 0, "lazy.nvim operation failed:\n" .. table.concat(errors, "\n"))
end

local operations = {
  ["lazy-restore"] = function()
    lazy_operation("restore")
  end,
  ["lazy-clean"] = function()
    lazy_operation("clean")
  end,
  mason = function()
    require("mason-lock").restore_from_lockfile()
  end,
  treesitter = function()
    local updated = require("nvim-treesitter.install").update(nil, { summary = true }):wait()
    assert(updated, "Tree-sitter parser update failed")
  end,
}

function M.run(operation)
  local handler = assert(operations[operation], "unknown sync operation: " .. tostring(operation))
  handler()
end

return M
