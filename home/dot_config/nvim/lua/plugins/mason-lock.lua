return {
  -- Mason has no native lockfile; this adds one. :MasonLock snapshots
  -- installed package versions into mason-lock.json (the default
  -- lockfile_path already matches this repo's committed file);
  -- :MasonLockRestore reinstalls exactly those versions.
  {
    "zapling/mason-lock.nvim",
    lazy = false,
    opts = {},
  },
}
