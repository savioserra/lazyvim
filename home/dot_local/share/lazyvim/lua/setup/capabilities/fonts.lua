local define = require("setup.contract")
return define({
	id = "fonts",
	requires = { "foundation" },
	setup = function(context)
		context.platform.configure_fonts()
	end,
	verify = function(context)
		context.platform.verify_fonts()
	end,
})
