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

local function complete_capabilities()
  local capabilities = vim.lsp.protocol.make_client_capabilities()
  local ok, cmp_nvim_lsp = pcall(require, "cmp_nvim_lsp")
  if ok then
    capabilities = vim.tbl_deep_extend("force", capabilities, cmp_nvim_lsp.default_capabilities())
  end
  return capabilities
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

  -- Load eagerly. cmp-nvim-lsp normally lazy-loads on InsertEnter, but its own
  -- completion-source registration also hooks InsertEnter (via its after/plugin
  -- script), which can race lazy.nvim's own InsertEnter loader on the very first
  -- insert of a session. Loading it at startup sidesteps that and guarantees
  -- `default_capabilities()` is available before any LSP client attaches.
  {
    "hrsh7th/cmp-nvim-lsp",
    lazy = false,
  },

  -- Merge nvim-cmp's LSP capabilities into every lspconfig-managed server
  -- directly, instead of relying solely on the nvim-cmp extra's own
  -- InsertEnter-gated `vim.lsp.config("*", ...)` registration.
  {
    "neovim/nvim-lspconfig",
    dependencies = { "hrsh7th/cmp-nvim-lsp" },
    opts = function(_, opts)
      opts.servers = opts.servers or {}
      opts.servers["*"] = vim.tbl_deep_extend("force", opts.servers["*"] or {}, {
        capabilities = complete_capabilities(),
      })
    end,
  },

  {
    "pmizio/typescript-tools.nvim",
    dependencies = { "nvim-lua/plenary.nvim", "neovim/nvim-lspconfig", "hrsh7th/cmp-nvim-lsp" },
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
    config = function(_, opts)
      opts.capabilities = complete_capabilities()
      require("typescript-tools").setup(opts)

      -- Work around two upstream bugs that leave `<leader>sS` (workspace/symbol)
      -- stuck loading forever, or silently empty, instead of returning results:
      -- 1. It resolves the "current file" via `vim.fn.bufnr("$")` (highest
      --    buffer number), not the actually-active buffer -- any incidental
      --    unlisted scratch buffer (e.g. mini.icons' filetype-match scratch)
      --    outranks it. Worse, `<leader>sS` itself opens a Snacks picker with
      --    its own unnamed prompt buffer *before* sending the request, so even
      --    "the active buffer" at request time is never the real file -- it's
      --    the picker's own buffer (empty name, filetype snacks_picker_input).
      --    Either way tsserver gets sent a bogus/empty file and replies
      --    `success = false, message = "No Project."`.
      -- 2. On that (or any) error response, `body` is the raw error table, not
      --    an item list, and indexing it as one throws before a response is
      --    ever sent, orphaning the pending request.
      -- https://github.com/pmizio/typescript-tools.nvim/issues/357
      -- Drop this once upstream fixes protocol/workspace/symbol.lua.
      local ts_filetypes = {
        javascript = true,
        javascriptreact = true,
        ["javascript.jsx"] = true,
        typescript = true,
        typescriptreact = true,
        ["typescript.tsx"] = true,
      }

      -- Never trust "the current buffer": the picker that triggers this request
      -- has already stolen focus for its own prompt buffer by the time it fires.
      -- Falling back to "any loaded TS/JS buffer" isn't enough either -- in an
      -- Nx-style monorepo each app is usually its own isolated tsconfig
      -- project, so grabbing an arbitrary buffer (e.g. the first one by buffer
      -- number) can anchor the search to a *different* project than the one
      -- you're actually working in, silently missing every real match.
      -- Track the most recently entered real TS/JS buffer instead, so the
      -- anchor always reflects what you were actually editing.
      local last_ts_buf_name = nil
      vim.api.nvim_create_autocmd("BufEnter", {
        callback = function(args)
          if vim.bo[args.buf].buflisted and ts_filetypes[vim.bo[args.buf].filetype] then
            last_ts_buf_name = vim.api.nvim_buf_get_name(args.buf)
          end
        end,
      })

      local function find_ts_buf_name()
        local cur = vim.api.nvim_get_current_buf()
        if vim.bo[cur].buflisted and ts_filetypes[vim.bo[cur].filetype] then
          return vim.api.nvim_buf_get_name(cur)
        end

        if last_ts_buf_name and last_ts_buf_name ~= "" then
          return last_ts_buf_name
        end

        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if
            vim.api.nvim_buf_is_loaded(buf)
            and vim.bo[buf].buflisted
            and ts_filetypes[vim.bo[buf].filetype]
          then
            return vim.api.nvim_buf_get_name(buf)
          end
        end

        return vim.api.nvim_buf_get_name(cur)
      end

      local ok, workspace_symbol = pcall(require, "typescript-tools.protocol.workspace.symbol")
      if ok then
        local ts_utils = require("typescript-tools.protocol.utils")
        function workspace_symbol.handler(request, response, params)
          local buf_name = find_ts_buf_name()

          request({
            command = "navto",
            arguments = { searchValue = params.query, file = buf_name },
          })

          local body = coroutine.yield()
          if type(body) ~= "table" or not vim.islist(body) then
            response({})
            return
          end

          response(vim.tbl_map(function(item)
            return {
              name = item.name,
              kind = ts_utils.get_lsp_symbol_kind(item.kind),
              containerName = item.containerName,
              location = {
                uri = vim.uri_from_fname(item.file),
                range = ts_utils.convert_tsserver_range_to_lsp(item),
              },
              tags = (item.kindModifiers or ""):find("deprecated", 1, true) and { 1 } or nil,
            }
          end, vim.tbl_filter(function(item)
            return item.file ~= nil
          end, body)))
        end
      end
    end,
  },
}
