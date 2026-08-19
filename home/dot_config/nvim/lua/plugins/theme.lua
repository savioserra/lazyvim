return {
  {
    "jacoborus/tender.vim",
    lazy = false,
    priority = 1000,
    config = function()
      vim.cmd.colorscheme("tender")

      -- tender.vim gives floating windows and the completion menu a blue-tinted
      -- background (#335261) instead of the main editor background (#282828).
      -- Several of its own text colors -- Comment (#666666) especially -- were
      -- tuned for contrast against the main bg and become hard to read against
      -- that blue tint (~1.45:1, vs ~2.57:1 in the editor itself). Repoint those
      -- surfaces to the same neutral dark family as the main bg instead, so
      -- every color that already works in the editor keeps working in floats.
      -- Also fixes FloatBorder, which tender defines as fg == bg (invisible).
      local function fix_tender_contrast()
        vim.api.nvim_set_hl(0, "NormalFloat", { bg = "#202020", fg = "#eeeeee" })
        vim.api.nvim_set_hl(0, "FloatBorder", { bg = "#202020", fg = "#999999" })
        vim.api.nvim_set_hl(0, "Pmenu", { bg = "#202020", fg = "#eeeeee" })
        vim.api.nvim_set_hl(0, "Visual", { bg = "#323232" })
      end

      fix_tender_contrast()
      vim.api.nvim_create_autocmd("ColorScheme", {
        pattern = "tender",
        callback = fix_tender_contrast,
      })
    end,
  },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "tender",
    },
  },
}
