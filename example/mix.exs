defmodule MeshExample.MixProject do
  use Mix.Project

  def project do
    [
      app: :mesh_example,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MeshExample.Application, []}
    ]
  end

  defp deps do
    [
      {:mesh, path: ".."},
      {:libcluster, "~> 3.3"}
    ]
  end
end
