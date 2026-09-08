local function import_vscode_settings(namespaces)
	return function(params, config)
		local ok, neoconf = pcall(require, "neoconf")
		if not ok then
			return
		end

		local root_dir = config.root_dir
			or (params.rootUri and vim.uri_to_fname(params.rootUri))
			or (
				params.workspaceFolders
				and params.workspaceFolders[1]
				and vim.uri_to_fname(params.workspaceFolders[1].uri)
			)
		if not root_dir then
			return
		end

		local vscode = neoconf.get("vscode", {}, { file = root_dir })
		local imported = {}
		for _, namespace in ipairs(namespaces) do
			if vscode[namespace] then
				imported[namespace] = vscode[namespace]
			end
		end

		config.settings = config.settings or {}
		for namespace, settings in pairs(imported) do
			config.settings[namespace] = vim.tbl_deep_extend("force", config.settings[namespace] or {}, settings)
		end
	end
end

return {
	{
		"neovim/nvim-lspconfig",
		opts = {
			codelens = { enabled = true },
			servers = {
				tailwindcss = {
					before_init = import_vscode_settings({ "tailwindCSS" }),
					settings = {
						tailwindCSS = { classFunctions = { "clsx", "classNames", "cn", "cva" } },
					},
				},
				html = {},
				cssls = {},
				emmet_language_server = {},
			},
		},
	},
}
