return function(profile)
	return {
		foundation = require("setup.features.foundation"),
		fonts = require("setup.features.fonts"),
		node = require("setup.features.node"),
		pi = require("setup.features.pi"),
		go = require("setup.features.go"),
		onepassword = require("setup.features.onepassword"),
		nvim = require("setup.features.nvim")(profile),
		tmux = require("setup.features.tmux"),
	}
end
