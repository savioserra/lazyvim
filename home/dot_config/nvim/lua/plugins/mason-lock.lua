return {
  -- Mason has no native lockfile; this adds one. :MasonLock snapshots
  -- installed package versions into mason-lock.json (the default
  -- lockfile_path already matches this repo's committed file);
  -- :MasonLockRestore reinstalls exactly those versions. Replaces the old
  -- Go CLI's `lock-mason`/`restore --mason-only` commands.
  {
    "zapling/mason-lock.nvim",
    lazy = false,
    opts = {},
  },
}
