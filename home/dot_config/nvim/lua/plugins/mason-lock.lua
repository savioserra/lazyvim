local restore_timeout = 10 * 60 * 1000

local function sorted_keys(values)
  local keys = vim.tbl_keys(values)
  table.sort(keys)
  return keys
end

local function restore_locked(lock)
  local registry = require("mason-registry")
  local lock_data = vim.json.decode(lock.read_file(lock.lockfile_path))
  local failures = {}
  local handles = {}
  local pending = {}

  for _, package in ipairs(registry.get_installed_packages()) do
    if lock_data[package.name] == nil then
      local operation = "remove " .. package.name
      pending[operation] = true
      local started, handle = pcall(package.uninstall, package, {}, function(success, result)
        pending[operation] = nil
        if not success then
          failures[operation] = tostring(result)
        end
      end)

      if started then
        handles[operation] = handle
      else
        pending[operation] = nil
        failures[operation] = tostring(handle)
      end
    end
  end

  for package_name, package_version in pairs(lock_data) do
    local ok, package = pcall(registry.get_package, package_name)
    if not ok then
      failures[package_name] = tostring(package)
    else
      if package:is_installing() or package:is_uninstalling() then
        local idle = vim.wait(restore_timeout, function()
          return not package:is_installing() and not package:is_uninstalling()
        end, 100)
        if not idle then
          failures[package_name] = "timed out waiting for an existing Mason operation"
        end
      end

      if not failures[package_name]
        and not (package:is_installed() and package:get_installed_version() == package_version)
      then
        pending[package_name] = true
        local started, handle = pcall(package.install, package, { version = package_version }, function(success, result)
          pending[package_name] = nil
          if not success then
            failures[package_name] = tostring(result)
          end
        end)

        if started then
          handles[package_name] = handle
        else
          pending[package_name] = nil
          failures[package_name] = tostring(handle)
        end
      end
    end
  end

  local completed = vim.wait(restore_timeout, function()
    return next(pending) == nil
  end, 100)

  local timed_out = {}
  if not completed then
    timed_out = sorted_keys(pending)
    for operation in pairs(pending) do
      local handle = handles[operation]
      if handle and not handle:is_closed() then
        handle:terminate()
      end
    end
    local terminated = vim.wait(30000, function()
      return next(pending) == nil
    end, 100)
    if not terminated then
      error("Mason restore could not terminate timed-out operations: " .. table.concat(sorted_keys(pending), ", "))
    end
  end

  if #timed_out > 0 then
    error("Mason restore timed out: " .. table.concat(timed_out, ", "))
  end

  for package_name, package_version in pairs(lock_data) do
    local ok, package = pcall(registry.get_package, package_name)
    if ok and not failures[package_name] then
      local installed_version = package:is_installed() and package:get_installed_version() or nil
      if installed_version ~= package_version then
        failures[package_name] = ("expected %s, got %s"):format(package_version, installed_version or "not installed")
      end
    end
  end

  for _, package in ipairs(registry.get_installed_packages()) do
    if lock_data[package.name] == nil then
      failures["remove " .. package.name] = "package is still installed"
    end
  end

  if next(failures) then
    local messages = {}
    for _, package_name in ipairs(sorted_keys(failures)) do
      messages[#messages + 1] = package_name .. ": " .. failures[package_name]
    end
    error("Mason restore failed:\n" .. table.concat(messages, "\n"))
  end
end

local function restore(lock)
  local previous_restore_state = lock._restore_in_progress
  lock._restore_in_progress = true

  local ok, err = xpcall(function()
    restore_locked(lock)
  end, debug.traceback)

  -- Flush mason-lock's scheduled package listeners while writes are still
  -- suppressed, so a restore never rewrites the lockfile it is consuming.
  vim.wait(50, function()
    return false
  end, 10)
  lock._restore_in_progress = previous_restore_state

  if not ok then
    error(err, 0)
  end
  vim.notify("[mason-lock]: Restored Mason package versions from lockfile")
end

return {
  -- Mason has no native lockfile; this adds one. :MasonLock snapshots
  -- installed package versions into mason-lock.json (the default
  -- lockfile_path already matches this repo's committed file);
  -- :MasonLockRestore reinstalls exactly those versions.
  {
    "zapling/mason-lock.nvim",
    lazy = false,
    opts = {},
    config = function(_, opts)
      local lock = require("mason-lock")
      -- Headless startup may trigger LazyVim's automatic Mason installs before
      -- the explicit restore. Never let those events rewrite the applied lock.
      if #vim.api.nvim_list_uis() == 0 then
        lock._restore_in_progress = true
      end
      lock.setup(opts)
      -- Upstream waits only 60 seconds and can then rewrite a partially
      -- restored lockfile from late install events. Keep the public command,
      -- but make its headless behavior blocking and verifiable.
      lock.restore_from_lockfile = function()
        restore(lock)
      end
    end,
  },
}
