# The engine bridge shells out to the repository reporter through the pinned
# Neovim; without it those tests cannot run and are excluded cleanly.
if System.find_executable("nvim") == nil do
  IO.puts("pinned Neovim engine unavailable; excluding engine bridge tests")
  ExUnit.configure(exclude: :engine)
end

ExUnit.start()
