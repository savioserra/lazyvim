return {
  -- Move lines and visual selections with Alt-j/k.
  {
    "matze/vim-move",
    init = function()
      vim.g.move_map_keys = 0
    end,
    config = function()
      vim.keymap.set("n", "<A-k>", "<Plug>MoveLineUp", { remap = true, silent = true, desc = "Move line up" })
      vim.keymap.set("n", "<A-j>", "<Plug>MoveLineDown", { remap = true, silent = true, desc = "Move line down" })
      vim.keymap.set(
        "x",
        "<A-k>",
        "<Plug>MoveBlockCountLinesUp",
        { remap = true, silent = true, desc = "Move selection up" }
      )
      vim.keymap.set(
        "x",
        "<A-j>",
        "<Plug>MoveBlockCountLinesDown",
        { remap = true, silent = true, desc = "Move selection down" }
      )
    end,
  },

  -- Close and rename paired HTML/JSX tags.
  {
    "windwp/nvim-ts-autotag",
    opts = {},
  },
}
