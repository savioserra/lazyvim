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
      -- Also fixes FloatBorder, which tender defines as fg == bg (invisible),
      -- and LspInlayHint, which tender sets to #444444 against the #282828
      -- editor bg -- ~1.5:1 contrast, effectively unreadable inline type/param
      -- hints. #999999 (tender's own "grey1") lands ~5.2:1, readable but still
      -- visually secondary to actual code.
      local function fix_tender_contrast()
        vim.api.nvim_set_hl(0, "NormalFloat", { bg = "#202020", fg = "#eeeeee" })
        vim.api.nvim_set_hl(0, "FloatBorder", { bg = "#202020", fg = "#999999" })
        vim.api.nvim_set_hl(0, "Pmenu", { bg = "#202020", fg = "#eeeeee" })
        vim.api.nvim_set_hl(0, "Visual", { bg = "#323232" })
        vim.api.nvim_set_hl(0, "LspInlayHint", { fg = "#999999" })
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
