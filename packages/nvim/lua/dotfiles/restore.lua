local M = {}

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
