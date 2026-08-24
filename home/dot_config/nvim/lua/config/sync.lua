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
    local config = require("nvim-treesitter.config")
    local parser_dir = config.get_install_dir("parser")
    local info_dir = config.get_install_dir("parser-info")
    vim.fn.mkdir(info_dir, "p")

    -- LazyVim can begin installing parsers during startup. If another headless
    -- sync operation exits between writing the parser and its revision file,
    -- nvim-treesitter's updater assumes the missing file exists and aborts.
    -- An empty revision safely marks that parser for a forced refresh below.
    if vim.fn.isdirectory(parser_dir) == 1 then
      for name, kind in vim.fs.dir(parser_dir) do
        if kind == "file" then
          local language = name:match("^(.+)%.[^.]+$")
          local revision = language and vim.fs.joinpath(info_dir, language .. ".revision")
          if revision and vim.fn.filereadable(revision) == 0 then
            vim.fn.writefile({}, revision)
          end
        end
      end
    end

    local updated = require("nvim-treesitter.install").update(nil, { summary = true }):wait()
    assert(updated, "Tree-sitter parser update failed")
  end,
}

function M.run(operation)
  local handler = assert(operations[operation], "unknown sync operation: " .. tostring(operation))
  handler()
end

return M
