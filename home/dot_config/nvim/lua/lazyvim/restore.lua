local M = {}

function M.plugins()
  local lockfile = vim.fn.stdpath("config") .. "/lazy-lock.json"
  local lock = vim.json.decode(table.concat(vim.fn.readfile(lockfile), "\n"))
  local configured = require("lazy.core.config").plugins
  local mismatches = {}

  for name, expected in pairs(lock) do
    local plugin = configured[name]
    if not plugin or not vim.uv.fs_stat(plugin.dir) then
      table.insert(mismatches, name .. " is not installed")
    else
      local result = vim.system({ "git", "-C", plugin.dir, "rev-parse", "HEAD" }, { text = true }):wait()
      local actual = result.code == 0 and vim.trim(result.stdout or "") or "unreadable"
      if actual ~= expected.commit then
        table.insert(mismatches, string.format("%s is %s, expected %s", name, actual, expected.commit))
      end
    end
  end

  assert(#mismatches == 0, "plugin lock mismatches:\n" .. table.concat(mismatches, "\n"))
end

function M.parsers()
  local treesitter = require("nvim-treesitter")
  local installed = {}
  for _, language in ipairs(treesitter.get_installed()) do
    installed[language] = true
  end

  local missing = {}
  for _, language in ipairs(LazyVim.opts("nvim-treesitter").ensure_installed or {}) do
    if not installed[language] then
      table.insert(missing, language)
    end
  end

  if #missing == 0 then
    return
  end

  local success = treesitter.install(missing, { summary = true }):wait()
  assert(success, "one or more Tree-sitter parsers failed to install")
end

return M
