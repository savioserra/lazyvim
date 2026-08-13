return {
  -- Replace LazyVim's multi-pane dap-ui with one compact, switchable debugger view.
  {
    "rcarriga/nvim-dap-ui",
    enabled = false,
  },
  {
    "mfussenegger/nvim-dap",
    dependencies = { "igorlfs/nvim-dap-view" },
    keys = {
      {
        "<leader>du",
        function()
          require("dap-view").toggle()
        end,
        desc = "Toggle debugger UI",
      },
      {
        "<leader>de",
        function()
          require("dap-view").hover()
        end,
        desc = "Evaluate expression",
        mode = { "n", "x" },
      },
    },
  },
  {
    "igorlfs/nvim-dap-view",
    lazy = true,
    opts = {
      auto_toggle = true,
      follow_tab = true,
      winbar = {
        sections = {
          "watches",
          "scopes",
          "exceptions",
          "breakpoints",
          "threads",
          "repl",
          "console",
        },
        default_section = "scopes",
        controls = {
          enabled = true,
          position = "right",
        },
      },
      windows = {
        position = "below",
        size = 0.28,
      },
      hover = {
        border = "rounded",
      },
      help = {
        border = "rounded",
      },
    },
  },
}
