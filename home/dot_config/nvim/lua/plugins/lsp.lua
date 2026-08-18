local function import_vscode_settings(namespaces)
  return function(params, config)
    local ok, neoconf = pcall(require, "neoconf")
    if not ok then
      return
    end

    local root_dir = config.root_dir
      or (params.rootUri and vim.uri_to_fname(params.rootUri))
      or (params.workspaceFolders and params.workspaceFolders[1] and vim.uri_to_fname(params.workspaceFolders[1].uri))
    if not root_dir then
      return
    end

    local vscode = neoconf.get("vscode", {}, { file = root_dir })
    local imported = {}
    for _, namespace in ipairs(namespaces) do
      if vscode[namespace] then
        imported[namespace] = vscode[namespace]
      end
    end

    config.settings = config.settings or {}
    for namespace, settings in pairs(imported) do
      config.settings[namespace] = vim.tbl_deep_extend("force", config.settings[namespace] or {}, settings)
    end
  end
end

return {
  {
    "neovim/nvim-lspconfig",
    opts = {
      codelens = {
        enabled = true,
      },
      servers = {
        -- The Go extra supplies gopls settings, formatting, debugging, and tests.
        gopls = {},

        tailwindcss = {
          before_init = import_vscode_settings({ "tailwindCSS" }),
          settings = {
            tailwindCSS = {
              classFunctions = {
                "clsx",
                "classNames",
                "cn",
                "cva",
              },
            },
          },
        },

        -- Formatting remains owned by Prettier through Conform.
        html = {},
        cssls = {},
        emmet_language_server = {},
      },
    },
  },

  -- Let typescript-tools.nvim own TypeScript/JavaScript LSP setup.
  {
    "neovim/nvim-lspconfig",
    opts = function(_, opts)
      opts.servers = opts.servers or {}
      for _, server in ipairs({ "ts_ls", "tsserver", "vtsls", "tsgo" }) do
        opts.servers[server] = opts.servers[server] or {}
        opts.servers[server].enabled = false
      end

      opts.setup = opts.setup or {}
      opts.setup.ts_ls = nil
      opts.setup.tsserver = nil
      opts.setup.vtsls = nil
      opts.setup.tsgo = nil
    end,
  },

  {
    "pmizio/typescript-tools.nvim",
    dependencies = { "nvim-lua/plenary.nvim", "neovim/nvim-lspconfig" },
    ft = {
      "javascript",
      "javascriptreact",
      "javascript.jsx",
      "typescript",
      "typescriptreact",
      "typescript.tsx",
    },
    keys = {
      {
        "gD",
        "<cmd>TSToolsGoToSourceDefinition<cr>",
        desc = "Go to source definition",
      },
      {
        "gR",
        "<cmd>TSToolsFileReferences<cr>",
        desc = "File references",
      },
      {
        "<leader>cM",
        "<cmd>TSToolsAddMissingImports<cr>",
        desc = "Add missing imports",
      },
      {
        "<leader>cD",
        "<cmd>TSToolsFixAll<cr>",
        desc = "Fix all diagnostics",
      },
      {
        "<leader>co",
        "<cmd>TSToolsOrganizeImports<cr>",
        desc = "Organize imports",
      },
    },
    opts = {
      settings = {
        separate_diagnostic_server = false,
        expose_as_code_action = "all",
        complete_function_calls = true,
        include_completions_with_insert_text = true,
        tsserver_max_memory = "auto",
        tsserver_file_preferences = {
          includeInlayParameterNameHints = "all",
          includeInlayParameterNameHintsWhenArgumentMatchesName = true,
          includeInlayFunctionLikeReturnTypeHints = true,
          includeInlayFunctionParameterTypeHints = true,
        },
        tsserver_format_options = {
          allowIncompleteCompletions = false,
        },
        code_lens = "off",
        disable_member_code_lens = true,
        jsx_close_tag = {
          enable = true,
          filetypes = { "javascriptreact", "typescriptreact" },
        },
      },
    },
  },
}
