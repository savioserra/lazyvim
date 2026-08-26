return function(profile)
	return {
		foundation = require("setup.features.foundation"),
		fonts = require("setup.features.fonts"),
		node = require("setup.features.node"),
		pi = require("setup.features.pi"),
		["pi-skills"] = require("setup.features.pi-skills"),
		go = require("setup.features.go"),
		secrets = require("setup.features.secrets"),
		nvim = require("setup.features.nvim")(profile),
		tmux = require("setup.features.tmux"),
	}
end
