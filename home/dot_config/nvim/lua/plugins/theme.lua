return {
  {
    "catppuccin/nvim",
    name = "catppuccin",
    opts = {
      flavour = "macchiato",
      transparent_background = false,
      float = {
        transparent = false,
        solid = true,
      },
      dim_inactive = {
        enabled = true,
        shade = "dark",
        percentage = 0.08,
      },
      auto_integrations = true,
      integrations = {
        diffview = true,
        dropbar = {
          enabled = true,
          color_mode = true,
        },
        overseer = true,
      },
    },
  },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "catppuccin",
    },
  },
}
