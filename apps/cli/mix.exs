defmodule Workstation.CLI.MixProject do
  use Mix.Project

  def project do
    [
      app: :cli,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # test/support holds the shared deterministic-backend harness; it is part
  # of the cli test compile path only (never shipped in lib).
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:optimus, "~> 0.6"},
      {:jason, "~> 1.4"},
      {:term_ui, "== 2.0.0-rc.2"},
      {:stream_data, "~> 1.4", only: :test},
      {:core, in_umbrella: true},
      {:daemon, in_umbrella: true}
    ]
  end
end
