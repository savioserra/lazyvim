local jest_config_names = {
  "jest.config.ts",
  "jest.config.js",
  "jest.config.mjs",
  "jest.config.cjs",
}

local function nearest_jest_config(file)
  if not file or file == "" then
    return nil
  end

  return vim.fs.find(jest_config_names, {
    path = vim.fs.dirname(vim.fs.normalize(file)),
    upward = true,
  })[1]
end

return {
  -- Select the nearest Jest config in an Nx-style monorepo.
  {
    "nvim-neotest/neotest",
    dependencies = {
      "nvim-neotest/neotest-jest",
    },
    opts = {
      adapters = {
        ["neotest-jest"] = {
          jestCommand = "yarn jest",
          jestConfigFile = function(file)
            return nearest_jest_config(file) or "jest.config.ts"
          end,
          cwd = function(file)
            local config = nearest_jest_config(file)
            return config and vim.fs.dirname(config) or vim.uv.cwd()
          end,
        },
      },
    },
  },
}
