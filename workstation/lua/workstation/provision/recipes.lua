local M = {}

-- Public call-style recipe constructors for the generic file backend. Packages
-- bind this module once and build their dense `contributes` array from these
-- pure helpers; the envelope stays opaque to core and is interpreted only by
-- the explicitly registered providers in the composition root. Domain
-- compositors (for example the nvim-owned profile recipe) stay with their
-- owning package and are imported directly by their contributors.

M.chezmoi = require("workstation.provision.chezmoi").recipe
M.shell = require("workstation.provision.shell").recipe

return M
