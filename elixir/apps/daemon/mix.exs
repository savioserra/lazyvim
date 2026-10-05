defmodule Workstation.Daemon.MixProject do
  use Mix.Project

  def project do
    [
      app: :daemon,
      version: "0.1.0",
      build_path: "../../_build",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
      # Deliberately no `mod:`: a resident listener must never auto-boot from
      # `mix test`/`mix run` against the ambient HOME — the tree is started
      # explicitly by the daemon entrypoint (and by the suite, under a temp
      # home). Workstation.Daemon.Application.children/0 is the tree.
    ]
  end

  defp deps do
    [
      {:zoi, "~> 0.18"},
      {:jason, "~> 1.4"},
      {:core, in_umbrella: true}
    ]
  end
end
