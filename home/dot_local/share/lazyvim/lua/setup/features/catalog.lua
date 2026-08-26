return function(profile)
	return {
		foundation = require("setup.features.foundation"),
		fonts = require("setup.features.fonts"),
		node = require("setup.features.node"),
		go = require("setup.features.go"),
		nvim = require("setup.features.nvim")(profile),
		tmux = require("setup.features.tmux"),
	}
end
