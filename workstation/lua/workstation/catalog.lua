return {
	require("packages.foundation"),
	require("packages.fonts"),
	require("packages.node"),
	require("packages.agent"),
	require("packages.pi-skills"),
	require("packages.pi-ntfy-notifier"),
	require("packages.go"),
	require("packages.herdr"),
	require("packages.herdr-pi"),
	require("packages.secrets"),
	require("packages.nvim"),
	require("packages.typescript"),
	require("packages.elixir"),
	-- Declared after the core capabilities: graph ties among foundation's
	-- children follow declaration order, and theme must stay a dependent.
	require("packages.theme"),
	require("packages.tmux"),
}
