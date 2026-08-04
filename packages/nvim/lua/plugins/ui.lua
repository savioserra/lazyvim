return {
  -- IDE-style breadcrumbs and symbol menus in the winbar.
  {
    "Bekaboo/dropbar.nvim",
    lazy = false,
    keys = {
      {
        "<leader>;",
        function()
          require("dropbar.api").pick()
        end,
        desc = "Pick Winbar Symbol",
      },
      {
        "[;",
        function()
          require("dropbar.api").goto_context_start()
        end,
        desc = "Previous Winbar Context",
      },
      {
        "];",
        function()
          require("dropbar.api").select_next_context()
        end,
        desc = "Next Winbar Context",
      },
    },
  },

  -- Replace diagnostic virtual text with a cleaner inline display.
  {
    "rachartier/tiny-inline-diagnostic.nvim",
    event = "VeryLazy",
    priority = 1000,
    opts = {
      preset = "modern",
    },
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      diagnostics = {
        virtual_text = false,
      },
    },
  },

  -- Add language-aware highlighting to Blink's completion menu.
  {
    "xzbdmw/colorful-menu.nvim",
    lazy = true,
    opts = {},
  },
  {
    "saghen/blink.cmp",
    optional = true,
    dependencies = { "xzbdmw/colorful-menu.nvim" },
    opts = function(_, opts)
      local draw = opts.completion.menu.draw
      draw.columns = { { "kind_icon" }, { "label", gap = 1 } }
      draw.components = draw.components or {}
      draw.components.label = vim.tbl_deep_extend("force", draw.components.label or {}, {
        text = function(ctx)
          return require("colorful-menu").blink_components_text(ctx)
        end,
        highlight = function(ctx)
          return require("colorful-menu").blink_components_highlight(ctx)
        end,
      })
    end,
  },
}
