defmodule Workstation.Core.MixProject do
  use Mix.Project

  def project do
    [
      app: :core,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # Test-only: the discovery exclusion fixture under test/support must
      # be compiled into the test build so DiscoverTest can prove the
      # test-tree exclusion (a fixture that never reaches the code path
      # proves nothing).
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :public_key, :crypto]
    ]
  end

  defp deps do
    [
      {:stream_data, "~> 1.4", only: :test},
      # Test-only and deliberate: tokens_test decodes the theme fixture with
      # Jason. Undeclared, the module was only reachable when another
      # umbrella app's compiled dep happened to sit on the code path — a
      # shared-_build accident that flakes on isolated app runs.
      {:jason, "~> 1.4", only: :test}
    ]
  end
end
