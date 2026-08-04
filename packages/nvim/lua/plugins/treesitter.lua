return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      for _, parser in ipairs({
        "css",
        "go",
        "gomod",
        "gosum",
        "gowork",
        "html",
        "javascript",
        "json",
        "tsx",
        "typescript",
      }) do
        if not vim.tbl_contains(opts.ensure_installed, parser) then
          table.insert(opts.ensure_installed, parser)
        end
      end
    end,
  },
}
