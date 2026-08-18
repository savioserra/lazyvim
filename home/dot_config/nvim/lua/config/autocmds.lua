-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua

local organize_import_filetypes = {
  javascript = true,
  javascriptreact = true,
  typescript = true,
  typescriptreact = true,
}

local function organize_imports(bufnr)
  if not organize_import_filetypes[vim.bo[bufnr].filetype] then
    return
  end

  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/codeAction" })) do
    if
      client.name == "tsgo"
      or client.name == "vtsls"
      or client.name == "typescript-tools"
      or client.name == "tsserver"
      or client.name == "ts_ls"
    then
      local win = vim.fn.bufwinid(bufnr)
      if win == -1 then
        return
      end

      local params = vim.lsp.util.make_range_params(win, client.offset_encoding)
      params.context = {
        diagnostics = {},
        only = { "source.organizeImports" },
      }

      local response = client:request_sync("textDocument/codeAction", params, 2000, bufnr)
      for _, action in ipairs((response and response.result) or {}) do
        local command
        if type(action.command) == "table" then
          command = action.command
        elseif type(action.command) == "string" then
          command = action
        end

        -- Avoid interactive refactors like 'Move to file' during save-time organize imports.
        if type(command) == "table" and command.command == "interactive_codeaction" then
          goto continue
        end

        if action.data and not action.edit and client:supports_method("codeAction/resolve", bufnr) then
          local resolved = client:request_sync("codeAction/resolve", action, 2000, bufnr)
          action = (resolved and resolved.result) or action
        end

        if action.edit then
          vim.lsp.util.apply_workspace_edit(action.edit, client.offset_encoding)
        end

        if command then
          client:request_sync("workspace/executeCommand", command, 2000, bufnr)
        end
        return
      end
      ::continue::
    end
  end
end

vim.api.nvim_create_autocmd("BufWritePre", {
  group = vim.api.nvim_create_augroup("user_organize_imports", { clear = true }),
  pattern = { "*.js", "*.jsx", "*.ts", "*.tsx" },
  callback = function(event)
    organize_imports(event.buf)
  end,
  desc = "Organize JavaScript and TypeScript imports",
})

vim.opt.autoread = true

vim.api.nvim_create_autocmd({ "BufEnter", "CursorHold" }, {
  group = vim.api.nvim_create_augroup("user_checktime", { clear = true }),
  callback = function()
    if vim.bo.buftype == "" then
      vim.cmd("checktime")
    end
  end,
  desc = "Reload externally changed buffers",
})
